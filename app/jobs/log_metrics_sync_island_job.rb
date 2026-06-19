# frozen_string_literal: true

# LogMetricsSyncIslandJob — turns log lines into pre-aggregated counts for ONE
# island. The Fase-2 backend behind the dashboard log-count panels: instead of
# scanning the NDJSON warehouse on every card render (the MVP live-scan), this
# job tallies matches in the background and writes them as warehouse samples
# (source="log", metric="log_count"), so the card reads a cheap indexed series
# (with history → sparkline) and updates live on the broadcast.
#
# MODE-AGNOSTIC BY DESIGN: it reads the on-disk NDJSON warehouse
# (storage/logs/<island>/<pod>/<date>.ndjson), which BOTH the Ruby
# LogTailIslandJob AND the out-of-process Go poller write to (see
# Internal::PollerController — the binary writes to storage/logs/<id>/...). So
# there is NO `POLLER_SPAWN` guard: in poller mode this is the ONLY thing
# turning logs into counts.
#
# IDEMPOTENT recompute-window strategy (no fragile watermark):
#
#   - Each tick RECOMPUTES the live window [now-RECOMPUTE_WINDOW, now] for every
#     def: delete that def's log samples in the window, re-count, re-insert.
#     Running twice yields the same rows — zero double-count, and late-arriving
#     lines are absorbed (a bucket keeps getting recomputed until it ages out
#     of the window, by which point all its lines have landed — the window is
#     >> the ~30s tail lag).
#   - Deep history (older than the live window) is BACKFILLED once per def
#     (cache-gated), so a freshly-pinned filter shows its full range instantly.
#
# Buckets are 60s, keyed by a string slice of the line ts (no Time parse in the
# hot loop). The warehouse SUM-aggregates the per-bucket rows into the chart's
# render-buckets, same as the ingress counters.
class LogMetricsSyncIslandJob < ApplicationJob
  queue_as :default

  # Live window recomputed every tick. Comfortably larger than the log-tail
  # lag (~15s poll + ~15s controller) so a bucket is fully settled before it
  # exits the window and freezes.
  RECOMPUTE_WINDOW = 10.minutes

  # Deepest history a first-sight backfill walks — the log warehouse retention.
  RETENTION = LogTail::FilePath::RETENTION_DAYS.days

  # Upper bound on lines a single scan tallies. The live window is tiny; this
  # only bites a backfill over a very chatty pod's full retention. We count
  # line-by-line (only the per-bucket tallies are held in memory), so this is a
  # CPU guard, not a memory one. Hitting it under-counts deep history; the live
  # window stays exact.
  SCAN_CAP = 5_000_000

  def perform(island_id)
    island = Island.find_by(id: island_id)
    return unless island

    defs = LogMetric::Definition.all_for(island)
    return if defs.empty? # nothing pinned → fast no-op, zero file reads

    pod_map = build_pod_map(island)
    return if pod_map.empty? # no live pods to attribute lines to

    by_workload = defs.group_by { |d| [d.scope, d.name] }

    now = Time.current
    win_start = Time.at(((now.to_i - RECOMPUTE_WINDOW.to_i) / 60) * 60).utc # minute-aligned
    inserted = 0

    MetricSample.transaction do
      # Live window — recompute for all defs every tick (idempotent).
      inserted += recompute(island, by_workload, pod_map, defs, from: win_start, until_: now, boundary: win_start, side: :live)

      # Deep history — once per def (cache-gated; idempotent if it does re-run).
      defs.each do |d|
        next if backfilled?(d.key)

        recompute(island, {[d.scope, d.name] => [d]}, pod_map, [d], from: RETENTION.ago, until_: win_start, boundary: win_start, side: :history)
        mark_backfilled(d.key)
      end
    end

    MetricsDigestService.broadcast_metrics_tick(island) if inserted.positive?

    Rails.logger.info("log-metrics-sync island=#{island.key} defs=#{defs.size} inserted=#{inserted}")
  end

  private

  # recompute — count matches in [from, until_], delete this def-set's existing
  # log rows in the matching bucket range, and insert the fresh tallies (so a
  # re-run replaces rather than adds — idempotent). `boundary` (minute-aligned
  # win_start) partitions live vs history so a boundary bucket is owned by
  # exactly one phase (no overlap, no double count):
  #
  #   side: :live    → buckets >= boundary, delete [boundary..until_]
  #   side: :history → buckets <  boundary, delete [from...boundary]
  def recompute(island, by_workload, pod_map, defs, from:, until_:, boundary:, side:)
    b = boundary.to_i

    counts = count_buckets(island, by_workload, pod_map, from: from, until_: until_)
    counts.select! { |(_key, bucket), _n| (side == :live) ? bucket_epoch(bucket) >= b : bucket_epoch(bucket) < b }

    keys = defs.map(&:key)
    range = (side == :live) ? (b..until_.to_i) : (from.to_i...b)
    MetricSample.where(tenant_id: island.id, source: "log", name: keys, ts_epoch: range).delete_all

    rows = counts.map { |(key, bucket), count| sample_row(island, key, bucket, count) }

    MetricSample.bulk_insert(rows)
    rows.size
  end

  # sample_row — one warehouse row per (def, bucket): the match count for that
  # bucket. The agg (count/sum/avg/min/max) is applied at READ time over this
  # per-bucket count series, so the counter is agg-agnostic — it just tallies.
  def sample_row(island, key, bucket, count)
    {tenant_id: island.id, source: "log", ts_iso: bucket,
     payload: {source: "log", ts: bucket, name: key, log_count: count}.to_json}
  end

  # count_buckets — ONE pass over the window's lines, tallying every candidate
  # def's matches per bucket. Returns { [def_key, bucket_iso] => count }.
  def count_buckets(island, by_workload, pod_map, from:, until_:)
    counts = Hash.new(0)

    LogTail::Reader.each_line(
      island_id: island.id, pods: nil, from: from, until_: until_,
      content_search: nil, regex: false, limit: SCAN_CAP
    ) do |_pod, h|
      pod = (h["pod"] || h[:pod]).to_s
      workload = pod_map[pod]
      next unless workload

      candidates = by_workload[workload]
      next if candidates.nil? || candidates.empty?

      bucket = bucket_iso((h["ts"] || h[:ts]).to_s)
      next unless bucket

      record = record_for(h)
      candidates.each { |d| counts[[d.key, bucket]] += 1 if match?(d, record) }
    end

    counts
  end

  # build_pod_map — container name → its workload {scope, name}. Lines from a
  # container not in the live pod list (a dead replica still on disk) are
  # dropped — consistent with the live-scan MVP. Needs a (non-network) client
  # because IslandPods.compact guards on client presence even in warehouse mode.
  def build_pod_map(island)
    client = Voodu::Client.new(island)

    IslandPods.compact(client, island).each_with_object({}) do |p, map|
      name = (p["name"] || p[:name]).to_s
      next if name.empty?

      map[name] = [(p["scope"] || p[:scope]).to_s, (p["resource_name"] || p[:resource_name]).to_s]
    end
  end

  # record_for — the {msg, raw, level, stream} shape LogQuery predicates expect
  # (symbol keys; @message tests msg OR raw). Reader yields string-keyed JSON.
  def record_for(line)
    {
      msg: (line["msg"] || line[:msg]).to_s,
      raw: (line["raw"] || line[:raw]).to_s,
      level: (line["level"] || line[:level]).to_s,
      stream: (line["stream"] || line[:stream]).to_s
    }
  end

  def match?(definition, record)
    definition.predicate.call(record)
  rescue Regexp::TimeoutError
    # ReDoS backstop tripped (per-match timeout) — treat as non-match so one
    # pathological filter can't stall the whole sweep.
    false
  end

  # bucket_iso — floor an ISO8601(3) UTC ts to its minute via a string slice:
  # "2026-06-19T14:47:50.123Z" → "2026-06-19T14:47:00Z". nil for a short/blank
  # ts. UTC ISO strings sort lexicographically == chronologically, so callers
  # compare buckets as strings.
  def bucket_iso(ts)
    return nil if ts.length < 16

    "#{ts[0, 16]}:00Z"
  end

  def bucket_epoch(bucket_iso)
    Time.zone.parse(bucket_iso).to_i
  end

  def backfilled?(key)
    Rails.cache.read("log-metric:bf:#{key}").present?
  end

  def mark_backfilled(key)
    Rails.cache.write("log-metric:bf:#{key}", "1", expires_in: 7.days)
  end
end
