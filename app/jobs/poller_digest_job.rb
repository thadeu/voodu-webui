# frozen_string_literal: true

# PollerDigestJob — process one digest folder the Go binary dropped
# on disk. Picks up the `PollerDigest` receipt by `sync_hash`,
# dispatches to the right service (`MetricsDigestService` or
# `StateDigestService`), marks the row processed, removes the
# folder.
#
# On exception → marks the row failed + re-raises so ActiveJob's
# default retry policy runs. The `discard_on AlreadyProcessed`
# covers the idempotent re-enqueue path (Solid Queue at-least-once
# delivery + race between Go retry POST and Rails initial enqueue).
#
# State machine:
#
#                  ┌──────────┐ create!  ┌────────────┐ pick up   ┌────────────┐
#                  │ Go POST  │─────────▶│ status:    │──────────▶│ status:    │
#                  └──────────┘          │ "queued"   │           │ "processing"│
#                                        └────────────┘           └─────┬──────┘
#                                                                       │ ok / boom
#                                          ┌────────────────┐           │
#                                          │ status:        │◀──────────┤
#                                          │ "processed"    │           │
#                                          └────────────────┘           │
#                                                                       ▼
#                                          ┌────────────────┐
#                                          │ status:        │
#                                          │ "failed"       │  (retried by AJ)
#                                          └────────────────┘
class PollerDigestJob < ApplicationJob
  queue_as :default

  # SQLite is single-writer; under burst load the metrics ingest can
  # race against the snapshot transaction. Retry the few-ms lock
  # blip rather than bouncing it back to the receipt as a failure.
  retry_on ActiveRecord::StatementInvalid, wait: :polynomially_longer, attempts: 5

  # If we re-process a row that's already terminal (Solid Queue
  # at-least-once duplicate, operator-triggered replay, etc.), no-op
  # WITHOUT burning a retry slot — discard immediately.
  discard_on PollerDigest::AlreadyProcessed

  def perform(sync_hash)
    digest = PollerDigest.find_by!(sync_hash: sync_hash)

    raise PollerDigest::AlreadyProcessed if digest.processed?

    digest.update!(status: "processing")

    folder_path = Rails.root.join("storage", "poller", digest.type, sync_hash)

    case digest.type
    when "metrics"
      MetricsDigestService.from_folder(folder_path: folder_path, server_id: digest.server_id)
    when "state"
      StateDigestService.from_folder(folder_path: folder_path, server_id: digest.server_id)
    else
      raise "unsupported digest type: #{digest.type.inspect}"
    end

    digest.update!(status: "processed", processed_at: Time.current)

    # Cleanup is best-effort — the folder might already be gone
    # (operator manually swept storage during dev). rm_rf is
    # idempotent: nonexistent paths return without raising.
    FileUtils.rm_rf(folder_path)
  rescue PollerDigest::AlreadyProcessed
    # Re-raise to let `discard_on` catch it. Without the explicit
    # rescue here, the generic StandardError rescue below would
    # mark the (already-processed) row as failed.
    raise
  rescue => e
    # Marker the receipt as failed so the dashboard / debug tooling
    # surfaces the dead row + reason. Then re-raise so ActiveJob's
    # retry policy kicks in (the retry will find the row and either
    # re-enter processing or, if the operator fixed the underlying
    # cause, succeed).
    digest&.update!(status: "failed", error_message: e.message)
    raise
  end
end
