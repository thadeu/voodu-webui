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

  # series_for — returns a bare array of Float values, ready to
  # pass to Components::UI::Sparkline's `data:` kwarg. The chart
  # doesn't render timestamps (sparklines are intentionally
  # axisless — the StatCard's `period` chip already tells the
  # operator the range), so we drop the `ts` and keep `value`s.
  #
  # Returns `[]` on any failure (controller offline, metric
  # unknown, etc.) so the caller's `if series.present?` guard in
  # the view degrades cleanly to "show the headline number,
  # no sparkline."
  def series_for(source:, metric:, range: "1h", interval: "auto", scope: nil, name: nil)
    return [] if @client.nil?

    payload = fetch(source: source, metric: metric, range: range, interval: interval, scope: scope, name: name)
    return [] unless payload.is_a?(Hash)

    points = Array(payload["series"])
    points.map { |p| p["value"].to_f }
  end

  # raw_payload exposes the full envelope (series + interval + truncated
  # flags) when a caller needs the metadata, not just the values. Used
  # by future pages that render the chart axis explicitly.
  def raw_payload(source:, metric:, range: "1h", interval: "auto", scope: nil, name: nil)
    return nil if @client.nil?

    fetch(source: source, metric: metric, range: range, interval: interval, scope: scope, name: name)
  end

  private

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
