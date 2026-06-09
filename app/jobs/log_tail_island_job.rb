# frozen_string_literal: true

# LogTailIslandJob — long-running tail consumer for ONE island.
#
# Opens a streaming connection to the controller's multi-pod log
# endpoint (one HTTP request covers every pod via the M61 fan-out
# already implemented controller-side), parses each line through
# LogTail::Parser, and persists structured NDJSON to disk via
# LogTail::Writer.
#
# Lifecycle:
#
#   1. Orchestrator (every 1m) calls `perform_later(island_id)`.
#   2. Acquire LogTail::TailLock — if already held, return early
#      (some other run is in flight).
#   3. Open SSE stream, parse chunks line-by-line, append.
#   4. Self-terminate after MAX_RUNTIME (1h) so the connection
#      gets cycled periodically (avoids zombie HTTP, gives
#      breathing room for config changes to take effect).
#   5. Lock released; orchestrator picks up on next tick.
#
# Resilience:
#
#   - Transport errors → re-raise so Solid Queue retries with its
#     default exponential backoff. The orchestrator will also
#     keep re-enqueuing every minute regardless.
#   - Auth errors → discard immediately (PAT revoked / scope
#     changed). Operator sees missing data, fixes PAT in /islands.
#   - Kill switch `LOG_TAIL_ENABLED=0` → early return at the top of
#     `perform`; orchestrator already filters but we double-check
#     here for jobs that were enqueued before the flag flipped.
#
# Queue: `:log_tail` (dedicated). Long-running here would starve
# `:default`, so we isolate. Configured in config/queue.yml with
# its own worker count.
class LogTailIslandJob < ApplicationJob
  queue_as :log_tail

  # Self-terminate at this point so the loop releases the lock
  # and lets the orchestrator re-spawn fresh (recovers cleanly
  # from any accumulated state drift).
  MAX_RUNTIME = 1.hour

  # Polling cadence — every N seconds we ask the controller for
  # "what changed since last poll". Each poll spawns one
  # `docker logs --since=<ts>` subprocess per pod on the
  # controller side (CLI invocation, not API call), which the
  # dockerd daemon services by opening the json-file driver,
  # seeking to the watermark, and streaming the delta. Per-poll
  # cost is modest BUT it's paid in a burst: all pods spawn at
  # ~the same moment, so the daemon sees N concurrent reads at
  # poll boundaries. With many pods this shows up as periodic
  # CPU spikes.
  #
  # 15s — balances:
  #   - Average ~7s lag between log line emitted and visible
  #     in /logs (browser also polls every 2s)
  #   - 3× less daemon churn vs the 5s we had before
  #   - Still fast enough that a typical debug session ("what
  #     happened 30s ago?") gets fresh data on the second look
  #
  # Override via `LOG_TAIL_POLL_SECONDS=30` (or any positive int)
  # if the controller's CPU still spikes — the warehouse keeps
  # collecting, just with more latency. Clamped to ≥5s so a
  # misconfigured `0` doesn't melt the controller.
  POLL_INTERVAL_SECONDS = [ENV.fetch("LOG_TAIL_POLL_SECONDS", 15).to_i, 5].max

  # How many lines to ask for per poll. Sized so a typical pod
  # (≤ 100 lines/sec) is fully covered by one poll; chatty pods
  # exceeding this rate will drop the overflow oldest-first
  # (docker logs returns the most recent N). For pods that
  # routinely outpace this, raise it — RAM cost is bounded by
  # the per-pod buffer × pod count for the duration of one poll.
  TAIL_PER_POLL = 500

  # Watermark TTL. The "newest ts we've persisted" survives across job
  # recycles (every MAX_RUNTIME) and process restarts so a new run
  # resumes with `?since=<watermark>` instead of cold-starting with
  # `tail=N` (which re-fetched + re-wrote the overlap every recycle —
  # the root cause of duplicate lines in the warehouse). Capped at the
  # log retention window: a resume after a longer gap than that falls
  # back to a bounded cold-start backfill, which the Writer's disk-
  # seeded dedupe then de-duplicates anyway.
  WATERMARK_TTL = LogTail::FilePath::RETENTION_DAYS.days

  # discard_on AuthError: orchestrator will keep trying, but
  # auth doesn't self-heal. Re-raising would create a retry
  # storm without value.
  discard_on Voodu::Client::AuthError

  def perform(island_id)
    # POLLER_SPAWN=1 — Go binary owns tailing. This job becomes a
    # no-op so we don't double-stream the same `docker logs`. The
    # check also catches in-flight enqueues that landed before the
    # flag flipped (orchestrator already filters too).
    return if ENV["POLLER_SPAWN"] == "1"

    return unless LogTail::Feature.enabled?
    return if LogTail::TailLock.held?(island_id)

    island = Island.find_by(id: island_id)
    return unless island

    LogTail::TailLock.acquire!(island_id) do
      run_tail(island)
    end
  end

  private

  def run_tail(island)
    client       = Voodu::Client.new(island)
    writer       = LogTail::Writer.new(island.id)
    started_at   = Time.current
    # Resume from the persisted watermark so a recycle/restart continues
    # with `since` instead of re-fetching a `tail=N` backfill. nil only
    # on a first-ever run (or after the watermark TTL lapsed).
    last_seen_ts = read_watermark(island.id)
    appended     = 0

    Rails.logger.info(
      "log-tail island=#{island.key} started (poll=#{POLL_INTERVAL_SECONDS}s tail=#{TAIL_PER_POLL})"
    )

    loop do
      elapsed = Time.current - started_at
      if elapsed > MAX_RUNTIME
        Rails.logger.info(
          "log-tail island=#{island.key} max_runtime reached, recycling " \
          "(#{appended} lines appended over #{elapsed.to_i}s)"
        )
        break
      end

      appended += poll_once(client, writer, last_seen_ts) do |new_ts|
        last_seen_ts = new_ts
        write_watermark(island.id, new_ts)
      end

      sleep POLL_INTERVAL_SECONDS
    end
  ensure
    writer&.close
  end

  # Watermark store — durable (solid_cache) so it outlives the job. Keyed
  # per island; value is the newest persisted ts (ISO8601 string).
  def watermark_key(island_id)
    "log-tail:watermark:#{island_id}"
  end

  def read_watermark(island_id)
    Rails.cache.read(watermark_key(island_id))
  end

  def write_watermark(island_id, ts)
    return if ts.blank?

    Rails.cache.write(watermark_key(island_id), ts, expires_in: WATERMARK_TTL)
  end

  # poll_once — single one-shot fetch from the controller. Two
  # modes based on whether we have a watermark:
  #
  #   - cold start (no watermark): asks for the last TAIL_PER_POLL
  #     lines as backfill. Now that the watermark is persisted, this
  #     only happens on a first-ever run or after the watermark TTL
  #     lapsed — NOT on every recycle. Establishes the watermark from
  #     the newest line returned.
  #
  #   - warm (watermark set): uses `?since=<last_seen_ts>` and
  #     unlimited tail. Docker returns ONLY lines newer than the
  #     watermark — zero redundancy, zero re-tail. Massively
  #     cheaper on bandwidth (loopback) AND on docker daemon
  #     (no need to seek backward N lines to apply --tail).
  #
  # Client-side dedupe (the `ts <= last_seen_ts` guard below) drops the
  # inclusive-boundary line; the Writer's disk-seeded dedupe backstops
  # any cold-start overlap, so a re-fetch can never re-write a line.
  def poll_once(client, writer, last_seen_ts)
    line_buffer = +""
    new_count   = 0
    newest_ts   = last_seen_ts

    # `since` advances the docker filter past everything we've
    # already persisted. The first poll has no `since` and uses
    # `tail` to bound the cold-start backfill instead.
    fetch_opts = if last_seen_ts
                   { follow: false, tail: 0, since: last_seen_ts }
                 else
                   { follow: false, tail: TAIL_PER_POLL }
                 end

    client.logs_stream_multi(**fetch_opts) do |chunk|
      line_buffer << chunk
      while (idx = line_buffer.index("\n"))
        raw_line = line_buffer.slice!(0..idx).chomp
        next if raw_line.empty?

        parsed = LogTail::Parser.parse(raw_line)
        ts     = parsed[:ts]

        # Defensive client-side dedupe — `--since` is inclusive
        # (docker returns lines AT the watermark too), so without
        # this guard we'd re-append the boundary line each poll.
        # ISO8601 string compare works because the parser
        # normalises everything to UTC.
        next if last_seen_ts && ts && ts <= last_seen_ts

        writer.append(parsed[:pod], parsed)
        new_count += 1
        newest_ts = ts if ts && (newest_ts.nil? || ts > newest_ts)
      end
    end

    yield(newest_ts) if newest_ts != last_seen_ts && block_given?

    new_count
  rescue Voodu::Client::Error => e
    Rails.logger.warn("log-tail poll error: #{e.class}: #{e.message}")
    0
  end
end
