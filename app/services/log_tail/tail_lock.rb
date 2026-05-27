# frozen_string_literal: true

# LogTail::TailLock — Rails.cache-based mutex so that at most one
# LogTailIslandJob runs per island at a time.
#
# Why not ActiveJob's `limits_concurrency`? Solid Queue 0.x's
# implementation BLOCKS subsequent jobs at the concurrency limit,
# building up an enqueue backlog when the orchestrator fires every
# minute. We want the opposite: SKIP enqueue when one is already
# running. A cache-key lock is the simplest semantic that fits.
#
# Lock TTL = 70 minutes (slightly longer than the job's 1h
# self-terminate budget) so a job that crashes without explicit
# release still frees the slot eventually instead of locking the
# island forever.
#
# Usage:
#
#   # Orchestrator:
#   LogTail::TailLock.held?(island.id) ? next : LogTailIslandJob.perform_later(island.id)
#
#   # Inside the job:
#   LogTail::TailLock.acquire!(island_id) do
#     # tail loop
#   end
#
# `acquire!` writes the lock, yields, and releases on return — even
# on exception. The block form is the only safe interface; callers
# never touch the keys directly.
module LogTail
  module TailLock
    LOCK_TTL = 70.minutes

    module_function

    def held?(island_id)
      Rails.cache.exist?(key(island_id))
    end

    def acquire!(island_id)
      Rails.cache.write(key(island_id), Time.current.iso8601(3), expires_in: LOCK_TTL)
      yield
    ensure
      Rails.cache.delete(key(island_id))
    end

    def key(island_id)
      "log-tail:lock:#{island_id}"
    end
  end
end
