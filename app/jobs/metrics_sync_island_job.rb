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
    # POLLER_SPAWN=1 — the Go binary owns the per-island NDJSON
    # pull; this job becomes a no-op so we don't double-fetch the
    # same delta. Same flag as the log_tail jobs and the state
    # jobs — single switch, all three lanes. Per-stream rollback
    # (metrics-only off) lives on the binary side via
    # `POLLER_METRICS=0`.
    return if ENV["POLLER_SPAWN"] == "1"

    island = Island.find_by(id: island_id)
    return unless island # deleted between orchestrator + job dispatch

    client  = Voodu::Client.new(island)
    last_ts = MetricSample.last_ts_for(island.id)

    # Stream the controller's NDJSON into MetricsDigestService — the
    # same persist + broadcast path the Go-fed PollerDigestJob uses.
    # Keeps the wire shape, BATCH_SIZE, and broadcast contract in
    # one place instead of forking the logic across two jobs.
    rows = Enumerator.new do |yielder|
      client.metrics_dump(since: last_ts) { |row| yielder << row }
    end

    total = MetricsDigestService.ingest_lines(island: island, rows: rows)

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
