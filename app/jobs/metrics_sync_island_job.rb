# frozen_string_literal: true

# MetricsSyncIslandJob — pulls the NDJSON delta for ONE island and
# persists it into the local metrics warehouse (MetricSample model
# on the `metrics` SQLite database).
#
# Sliding window mechanics:
#
#   - last_ts = MAX(ts_epoch) in the warehouse for this tenant.
#     Cold warehouse (no rows yet) → 0 → controller interprets as
#     "dump retention window" and backfills 7d in one pull.
#   - Subsequent ticks pass last_ts → controller returns only rows
#     with strict `ts > since` → no duplicates, no gaps.
#   - If the controller's sampler hasn't ticked since the last sync
#     (lag < 15s controller cadence), the dump returns 0 bytes and
#     the job is a fast no-op. Stays cheap on every tick.
#
# Batching: we accumulate yielded rows up to BATCH_SIZE then flush
# via MetricSample.bulk_insert. One round-trip per batch instead of
# one per row. 500 chosen to keep peak memory bounded (~500 × ~250B
# payload ≈ 125 KB per batch) while still amortising INSERT cost
# enough to handle a 7d backfill (~10K rows = 20 batches).
#
# Error handling: Faraday transport errors bubble up as
# Voodu::Client::Error; solid_queue retries per its default policy
# (5 attempts, exponential backoff). Auth/scope errors won't
# self-recover, so we discard rather than burning the retry budget
# (operator notices via stale-warehouse symptoms on the UI side).
class MetricsSyncIslandJob < ApplicationJob
  queue_as :default

  # 500-row batches balance INSERT amortisation against bounded peak
  # memory + reasonable progress in the face of mid-job interrupts.
  BATCH_SIZE = 500

  # Bail without consuming retries on auth/scope errors — a PAT was
  # revoked or has insufficient scope; retrying every 30s won't fix
  # it. Operator sees the warehouse stop advancing for that island
  # and can re-configure the PAT in /islands/:id/edit.
  discard_on Voodu::Client::AuthError

  def perform(island_id)
    island = Island.find_by(id: island_id)
    return unless island # deleted between orchestrator + job dispatch

    client  = Voodu::Client.new(island)
    last_ts = MetricSample.last_ts_for(island.id)

    batch = []
    total = 0

    client.metrics_dump(since: last_ts) do |row|
      batch << row.merge(tenant_id: island.id)
      next if batch.size < BATCH_SIZE

      MetricSample.bulk_insert(batch)
      total += batch.size
      batch.clear
    end

    if batch.any?
      MetricSample.bulk_insert(batch)
      total += batch.size
    end

    # Log at INFO so a `tail -f log/development.log | grep metrics-sync`
    # gives a continuous feed of "how alive is the warehouse?" without
    # opening a SQLite session. Empty pulls log too — that's the
    # signal the sliding window is caught up.
    Rails.logger.info(
      "metrics-sync island=#{island.key} tenant=#{island.id} " \
      "since=#{last_ts} inserted=#{total}"
    )
  end
end
