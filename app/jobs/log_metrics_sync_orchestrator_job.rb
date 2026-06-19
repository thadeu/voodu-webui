# frozen_string_literal: true

# LogMetricsSyncOrchestratorJob — fans out one LogMetricsSyncIslandJob per
# island each tick (mirrors MetricsSyncOrchestratorJob).
#
# NO `POLLER_SPAWN` guard — unlike the metrics/state/log-tail orchestrators,
# this one must run in BOTH modes. The per-island job reads the on-disk NDJSON
# warehouse (which the Go poller also writes to), so it's the only thing turning
# logs into counts when the binary owns tailing. An island with no log-count
# panels is a fast no-op (the per-island job returns before any file read).
class LogMetricsSyncOrchestratorJob < ApplicationJob
  queue_as :default

  def perform
    Island.find_each do |island|
      LogMetricsSyncIslandJob.perform_later(island.id)
    end
  end
end
