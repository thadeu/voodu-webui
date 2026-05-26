# frozen_string_literal: true

# StateSyncOrchestratorJob — fans out per-island state syncs.
#
# Recurs every 10 seconds (see config/recurring.yml). Each tick:
#
#   1. Enumerate every registered Island.
#   2. perform_later one StateSyncIslandJob per island, so each
#      island's HTTP fetch + snapshot replacement runs in parallel
#      against solid_queue's worker pool.
#
# Sibling of `MetricsSyncOrchestratorJob` — same fan-out pattern,
# same rationale (per-island isolation, retry granularity, worker
# concurrency knob lives in solid_queue config). The two jobs are
# independent: state-sync handles pod runtime + system snapshots
# (every 10s), metrics-sync handles time-series warehouse delta
# (every 14s).
#
# Empty-island case (greenfield WebUI before any island is added)
# is a no-op — the job still fires but does nothing. Cheap.
class StateSyncOrchestratorJob < ApplicationJob
  queue_as :default

  def perform
    Island.find_each do |island|
      StateSyncIslandJob.perform_later(island.id)
    end
  end
end
