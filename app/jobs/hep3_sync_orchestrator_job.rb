# frozen_string_literal: true

# Hep3SyncOrchestratorJob — top of the HEP3 poller fanout tree (recurs
# every 15s, see config/recurring.yml). Each tick enqueues one
# Hep3PollerJob per (island, configured reader instance), so each
# reader's /export drain runs in parallel on solid_queue's pool with
# per-instance retry isolation (same pattern as MetricsSyncOrchestratorJob).
#
# Gated on local state: only islands whose controller has the voodu-hep3
# plugin installed (System#plugin_installed?, from the /system sync) AND
# that have a Table panel pointing at a hep3 reader get polled. The set
# of readers is DEMAND-DRIVEN — derived from the dashboards' table panels
# (MetricDashboard.table_readers_for), so adding a Table panel is what
# turns the poller on for that reader. Everything else is a cheap no-op.
class Hep3SyncOrchestratorJob < ApplicationJob
  queue_as :default

  def perform
    Island.find_each do |island|
      next unless island.plugin_installed?("hep3")

      MetricDashboard.table_readers_for(island, source: "hep3").each do |reader|
        Hep3PollerJob.perform_later(island.id, reader[:scope], reader[:name])
      end
    end
  end
end
