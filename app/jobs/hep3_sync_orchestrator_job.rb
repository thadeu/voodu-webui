# frozen_string_literal: true

# Hep3SyncOrchestratorJob — top of the HEP3 poller fanout tree (recurs
# every 15s, see config/recurring.yml). Each tick enqueues one
# Hep3PollerJob per (server, configured reader instance), so each
# reader's /export drain runs in parallel on solid_queue's pool with
# per-instance retry isolation (same pattern as LogMetricsSyncOrchestratorJob).
#
# Gated on local state: only servers whose controller has the voodu-hep3
# plugin installed (System#plugin_installed?, from the /system sync) AND
# that have a Table panel pointing at a hep3 reader get polled. The set
# of readers is DEMAND-DRIVEN — derived from the dashboards' table panels
# (MetricDashboard.table_readers_for), so adding a Table panel is what
# turns the poller on for that reader. Everything else is a cheap no-op.
class Hep3SyncOrchestratorJob < ApplicationJob
  queue_as :default

  def perform
    Server.find_each do |server|
      next unless server.plugin_installed?("hep3")

      # Every reader RUNNING on the box (the pod snapshot), plus any a Table
      # panel still names (a reader that left the snapshot but has a panel
      # keeps draining, so a restart never leaves a gap). It used to be the
      # panels alone, and a server with the plugin installed and no dashboard
      # collected nothing — the Logs → call-flow bridge answered "Call not
      # found" for every call while the reader sat there with the data.
      readers = server.hep3_readers + MetricDashboard.table_readers_for(server, source: "hep3")

      readers.uniq.each do |reader|
        Hep3PollerJob.perform_later(server.id, reader[:scope], reader[:name])
      end
    end
  end
end
