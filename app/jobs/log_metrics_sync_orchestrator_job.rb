# frozen_string_literal: true

# LogMetricsSyncOrchestratorJob — fans out one LogMetricsSyncServerJob per
# server each tick (mirrors MetricsSyncOrchestratorJob).
#
# NO `POLLER_SPAWN` guard — unlike the metrics/state/log-tail orchestrators,
# this one must run in BOTH modes. The per-server job reads the on-disk NDJSON
# warehouse (which the Go poller also writes to), so it's the only thing turning
# logs into counts when the binary owns tailing. An server with no log-count
# panels is a fast no-op (the per-server job returns before any file read).
class LogMetricsSyncOrchestratorJob < ApplicationJob
  queue_as :default

  def perform
    Server.find_each do |server|
      LogMetricsSyncServerJob.perform_later(server.id)
    end
  end
end
