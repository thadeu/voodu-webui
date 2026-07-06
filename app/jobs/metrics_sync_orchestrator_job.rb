# frozen_string_literal: true

# MetricsSyncOrchestratorJob — top of the warehouse sync fanout tree.
#
# Recurs every 30 seconds (see config/recurring.yml). Each tick:
#
#   1. Enumerate every registered Server.
#   2. perform_later one MetricsSyncServerJob per server, so each
#      server's HTTP fetch + bulk_insert runs in parallel against
#      solid_queue's worker pool.
#
# Why fan out instead of looping in-process?
#
#   - Parallelism: 1 server's slow controller (rate-limited PAT, busy
#     host) doesn't block the others.
#   - Retry isolation: solid_queue retries the failing server's job
#     without re-pulling the healthy ones.
#   - Worker concurrency knob lives in solid_queue config, not here —
#     keeps this job dumb. With N workers and M servers, M ÷ N rounds
#     happen per tick; small ops shops have M ≤ N → all parallel.
#
# Empty-server case (greenfield WebUI before any server is added) is
# a no-op — the job still fires every 30s but does nothing. Cheap.
class MetricsSyncOrchestratorJob < ApplicationJob
  queue_as :default

  def perform
    # POLLER_SPAWN=1 — the Go binary owns the per-server metrics
    # dump and POSTs a digest envelope to Rails for ingest via
    # PollerDigestJob (same persist path used here, just fed by
    # the binary instead of by Faraday). This orchestrator becomes
    # a no-op so we don't double-pull the same NDJSON delta. Same
    # flag as the log_tail orchestrator and the state orchestrator
    # — one switch toggles all three lanes. Per-stream rollback
    # (metrics-only off) lives on the Go side via `POLLER_METRICS=0`.
    return if ENV["POLLER_SPAWN"] == "1"

    Server.find_each do |server|
      MetricsSyncServerJob.perform_later(server.id)
    end
  end
end
