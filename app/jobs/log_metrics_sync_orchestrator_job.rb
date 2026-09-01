# frozen_string_literal: true

# LogMetricsSyncOrchestratorJob — fans out one LogMetricsSyncServerJob per
# server each tick (the same fan-out shape the Go poller replaced for metrics and state).
#
# Still a Solid Queue job, unlike the fetching that moved into the Go poller:
# the per-server job reads the on-disk NDJSON warehouse the poller writes and
# turns lines into counts, and counting against alert rules is Ruby's half of
# the deal. A server with no log-count panels is a fast no-op (the per-server
# job returns before any file read).
class LogMetricsSyncOrchestratorJob < ApplicationJob
  queue_as :default

  def perform
    Server.find_each do |server|
      LogMetricsSyncServerJob.perform_later(server.id)
    end
  end
end
