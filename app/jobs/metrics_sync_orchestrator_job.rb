# frozen_string_literal: true

# MetricsSyncOrchestratorJob — top of the warehouse sync fanout tree.
#
# Recurs every 30 seconds (see config/recurring.yml). Each tick:
#
#   1. Enumerate every registered Island.
#   2. perform_later one MetricsSyncIslandJob per island, so each
#      island's HTTP fetch + bulk_insert runs in parallel against
#      solid_queue's worker pool.
#
# Why fan out instead of looping in-process?
#
#   - Parallelism: 1 island's slow controller (rate-limited PAT, busy
#     host) doesn't block the others.
#   - Retry isolation: solid_queue retries the failing island's job
#     without re-pulling the healthy ones.
#   - Worker concurrency knob lives in solid_queue config, not here —
#     keeps this job dumb. With N workers and M islands, M ÷ N rounds
#     happen per tick; small ops shops have M ≤ N → all parallel.
#
# Empty-island case (greenfield WebUI before any island is added) is
# a no-op — the job still fires every 30s but does nothing. Cheap.
class MetricsSyncOrchestratorJob < ApplicationJob
  queue_as :default

  def perform
    Island.find_each do |island|
      MetricsSyncIslandJob.perform_later(island.id)
    end
  end
end
