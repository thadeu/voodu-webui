# frozen_string_literal: true

# MetricsData — chart-ready time-series fetcher with per-card cache.
#
# OverviewData and PodDetailData call MetricsData.new(client, island)
# once per request, then ask for `series_for(...)` per StatCard.
# Misses go to the controller's /metrics endpoint; hits return
# instantly from Rails.cache (60s TTL — charts rarely move that fast).
#
# Cache TTL is intentionally LONGER than the sampler's 15s cadence:
# operators looking at a 1h chart don't notice the difference between
# 60s-old and live data, and the per-island request volume drops by
# ~4× on a busy session.
#
# Per-card / per-pod cache keys mean two operators (or two browser
# tabs) hitting the same chart share the cached fetch — same pattern
# as IslandHealth + pods_count.
class MetricsData
  CACHE_TTL = 60.seconds

  def initialize(client, island)
    @client = client
    @island = island
  end

  # points_for — returns rich points `[{ts:, value:, formatted:}]`
  # the new Sparkline consumes. Each point carries the original
  # timestamp + value + a human-readable string formatted for the
  # metric (`12.5%`, `512 MB`, `1.2 GB`, …) so the hover tooltip
  # doesn't have to know whether the metric is a percentage or a
  # byte count — that knowledge lives here, where the metric name
  # is in scope.
  #
  # Returns `[]` on any failure (controller offline, metric
  # unknown, etc.) so callers' `if points.present?` guard in the
  # view degrades cleanly to "show the headline number, no chart."
  def points_for(source:, metric:, range: "1h", interval: "auto", scope: nil, name: nil)
    return [] if @client.nil?

    payload = fetch(source: source, metric: metric, range: range, interval: interval, scope: scope, name: name)
    return [] unless payload.is_a?(Hash)

    formatter = formatter_for(metric)

    Array(payload["series"]).map do |p|
      val = p["value"].to_f
      {
        ts:        p["ts"],
        value:     val,
        formatted: formatter.call(val)
      }
    end
  end

  # series_for — legacy shape: bare `[Float]` for callers that
  # haven't moved to points_for yet. Kept so the migration to the
  # rich Sparkline can land in one repo without breaking
  # intermediate states. New code should prefer points_for.
  def series_for(source:, metric:, range: "1h", interval: "auto", scope: nil, name: nil)
    points_for(source: source, metric: metric, range: range, interval: interval, scope: scope, name: name)
      .map { |p| p[:value] }
  end

  # raw_payload exposes the full envelope (series + interval + truncated
  # flags) when a caller needs the metadata, not just the values. Used
  # by future pages that render the chart axis explicitly.
  def raw_payload(source:, metric:, range: "1h", interval: "auto", scope: nil, name: nil)
    return nil if @client.nil?

    fetch(source: source, metric: metric, range: range, interval: interval, scope: scope, name: name)
  end

  private

  # formatter_for — returns a callable that renders a metric value
  # as the operator-readable string the tooltip shows. Decisions
  # match the StatCard headline units (pod show: cpu_sub shows
  # `limit 0.5`; mem_used_label shows `512 MB` — tooltip must
  # speak the same dialect).
  #
  # Centralising here means a new metric needs ONE change (this
  # case statement) — Sparkline / Stimulus don't know about units.
  def formatter_for(metric)
    case metric
    when "cpu_percent"
      ->(v) { format("%.1f%%", v) }

    when /\Amem_/, /\Adisk_/
      method(:format_bytes)

    when /_delta_bytes\z/
      # Delta-per-tick rate — show as bytes/15s? Keep absolute
      # bytes for now since the chart timeline already implies the
      # period; user reads "100 MB in this bucket" naturally.
      method(:format_bytes)

    when /_bytes\z/
      method(:format_bytes)

    else
      ->(v) { v.round(2).to_s }
    end
  end

  # format_bytes — decimal kB/MB/GB matching `docker stats` (the
  # CLI operators already use). Mirror of PodDetailData#format_bytes
  # because tooltip rendering goes through this service.
  def format_bytes(b)
    b = b.to_f
    return "0 B"                                       if b.zero?
    return "#{b.round} B"                              if b < 1_000
    return "#{(b / 1_000.0).round(1)} kB"              if b < 1_000_000
    return "#{(b / 1_000_000.0).round(1)} MB"          if b < 1_000_000_000
    return "#{(b / 1_000_000_000.0).round(1)} GB"      if b < 1_000_000_000_000

    "#{(b / 1_000_000_000_000.0).round(1)} TB"
  end

  # fetch — Rails.cache-backed wrapper around Voodu::Client#metrics.
  # Errors are swallowed (return nil) so a flaky chart doesn't
  # poison the parent OverviewData/PodDetailData fetch. The
  # higher-level error banner on those pages already handles the
  # "can't reach controller" case.
  def fetch(source:, metric:, range:, interval:, scope:, name:)
    Rails.cache.fetch(cache_key(source, metric, range, interval, scope, name), expires_in: CACHE_TTL) do
      @client.metrics(
        source:   source,
        metric:   metric,
        range:    range,
        interval: interval,
        scope:    scope,
        name:     name
      )
    end
  rescue Voodu::Client::Error => e
    Rails.logger.warn("metrics: #{source}/#{metric} #{range}: #{e.class} #{e.message}")
    nil
  end

  # cache_key — namespaced per (island, source, metric, range,
  # interval, scope, name). Two browser tabs viewing the same chart
  # share the cache; switching range bypasses; another island gets
  # its own cell.
  def cache_key(source, metric, range, interval, scope, name)
    [
      "voodu:metrics:v1",
      "island:#{@island.id}",
      source, metric, range, interval,
      scope || "_", name || "_"
    ].join(":")
  end
end
