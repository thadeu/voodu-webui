# frozen_string_literal: true

# LogTailOrchestratorJob — fan-out scheduler that keeps one
# LogTailIslandJob in flight per island.
#
# Runs every 1 minute (see config/recurring.yml). On each tick:
#   1. Bail if kill switch is off (`LOG_TAIL_ENABLED=0`).
#   2. For each island, if no tail is currently running
#      (LogTail::TailLock not held), enqueue a fresh one.
#   3. Also enforces the per-island disk cap (2GB): skip enqueue
#      when the island's storage tree is already over budget.
#      The cap auto-relaxes as LogTailCleanupJob reaps old files.
#
# Same shape as StateSyncOrchestratorJob — small enough to be
# inlined; we keep it as its own class for symmetry + so the
# recurring schedule has a stable class name to reference.
class LogTailOrchestratorJob < ApplicationJob
  queue_as :default

  def perform
    # LOG_POLLER_SPAWN=1 — the out-of-process Go binary owns log
    # polling. This orchestrator becomes a no-op so the two systems
    # don't both spawn `docker logs` streams against the same pods.
    # Default (unset / "0") keeps the in-Rails Ruby polling path
    # alive; the flag is opt-in for the binary rollout AND a
    # rollback lever if the binary misbehaves.
    return if ENV["LOG_POLLER_SPAWN"] == "1"

    return unless LogTail::Feature.enabled?

    Island.find_each do |island|
      next if LogTail::TailLock.held?(island.id)
      next if over_disk_cap?(island.id)

      LogTailIslandJob.perform_later(island.id)
    end
  end

  private

  # over_disk_cap? — true when this island's tree of NDJSON files
  # exceeds the per-island cap (2GB). Logs a warning so operator
  # can see why tailing paused.
  def over_disk_cap?(island_id)
    bytes = LogTail::FilePath.island_disk_bytes(island_id)
    cap   = LogTail::FilePath::PER_ISLAND_CAP_BYTES

    return false if bytes < cap

    Rails.logger.warn(
      "log-tail orchestrator skipping island=#{island_id} " \
      "disk=#{(bytes / 1024.0 / 1024.0).round}MB cap=#{cap / 1024 / 1024}MB"
    )
    true
  end
end
