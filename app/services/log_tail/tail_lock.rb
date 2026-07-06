# frozen_string_literal: true

# LogTail::TailLock — Rails.cache-based mutex so that at most one
# LogTailServerJob runs per server at a time.
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
# server forever.
#
# Usage:
#
#   # Orchestrator:
#   LogTail::TailLock.held?(server.id) ? next : LogTailServerJob.perform_later(server.id)
#
#   # Inside the job:
#   LogTail::TailLock.acquire!(server_id) do
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

    def held?(server_id)
      Rails.cache.exist?(key(server_id))
    end

    def acquire!(server_id)
      Rails.cache.write(key(server_id), Time.current.iso8601(3), expires_in: LOCK_TTL)
      yield
    ensure
      Rails.cache.delete(key(server_id))
    end

    def key(server_id)
      "log-tail:lock:#{server_id}"
    end
  end
end
