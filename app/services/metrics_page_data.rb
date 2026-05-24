# frozen_string_literal: true

# MetricsPageData — assembles the four chart payloads for the
# /metrics page. Resolves the scope (host vs pod) into 4 metric
# slots and pulls each series via MetricsData#points_for.
#
# Per-scope chart layout (mirrors design-webui-inspiration's
# chartsForScope, pages-metrics.jsx lines 87-102):
#
#   host scope:
#     CPU      cpu_percent       %
#     Memory   mem_used_bytes    GB
#     Disk     disk_used_bytes   GB    (was disk-I/O rate; we now
#                                       have usage only — fine, the
#                                       chart's "rate of change of
#                                       usage" tells the same story)
#     Network  (absent — host-level net was removed in W7)
#
#   pod scope:
#     CPU      cpu_percent             %
#     Memory   mem_usage_bytes         MB
#     Net Rx   net_rx_delta_bytes      bytes
#     Net Tx   net_tx_delta_bytes      bytes
#
# 4 round-trips to /metrics per page load, each cached 60s by
# MetricsData. Hits are sequential because the metric serialised
# chart-by-chart over a single Faraday connection — parallelisation
# is a future win when round-trip cost dominates.
class MetricsPageData
  RANGES = {
    "5m"  => "5m",
    "15m" => "15m",
    "1h"  => "1h",
    "6h"  => "6h",
    "24h" => "24h",
    "7d"  => "7d",
    "30d" => "30d"
  }.freeze

  DEFAULT_RANGE = "1h"

  attr_reader :scope_kind, :scope_id, :range

  def initialize(client, island, scope_kind:, scope_id:, range:)
    @client     = client
    @island     = island
    @scope_kind = (scope_kind == "pod") ? "pod" : "host"
    @scope_id   = scope_id
    @range      = RANGES.key?(range) ? range : DEFAULT_RANGE

    @metrics = MetricsData.new(client, island)
  end

  # charts — array of `{label, color, unit, points}` ready for
  # ChartCard. Empty array when client is nil (no island selected).
  def charts
    return [] if @client.nil?

    chart_specs.map do |spec|
      points = fetch_points(spec[:metric], spec[:scale])

      # For :bytes_auto the unit is decided per chart inside
      # rescale_points; surface it back via the first point's
      # formatted string so the ChartCard headline shows the
      # right "MB" / "kB" / etc.
      unit = if spec[:scale] == :bytes_auto && points.any?
               points.first[:formatted].to_s.split(" ").last.to_s
             else
               spec[:unit]
             end

      {
        label:  spec[:label],
        color:  spec[:color],
        unit:   unit,
        points: points
      }
    end
  end

  # range_ms — duration in milliseconds for the chart's x-axis
  # math (it needs to know "where does the right edge land"
  # relative to now). Mirrors the inspiration's RANGES.ms.
  def range_ms
    case @range
    when "5m"  then 5 * 60 * 1000
    when "15m" then 15 * 60 * 1000
    when "1h"  then 60 * 60 * 1000
    when "6h"  then 6 * 60 * 60 * 1000
    when "24h" then 24 * 60 * 60 * 1000
    when "7d"  then 7 * 24 * 60 * 60 * 1000
    when "30d" then 30 * 24 * 60 * 60 * 1000
    else 60 * 60 * 1000
    end
  end

  # pod_record — the full pod hash from /pods?detail=true for the
  # active scope_id. Used by the page to render the pod's scope
  # subtitle ("pod x.aaaa · image:tag") and to find sibling
  # replicas for the ReplicaChips component.
  def pod_record
    return nil unless @scope_kind == "pod" && @client && @scope_id.present?

    all_pods.find { |p| (p["name"] || p[:name]) == @scope_id }
  end

  # sibling_replicas — pods sharing (scope, resource_name) with
  # the active pod. Empty when the active pod is the only one
  # (chips component hides itself when size < 2).
  def sibling_replicas
    p = pod_record
    return [] if p.nil?

    scope    = p["scope"] || p[:scope]
    resource = p["resource_name"] || p[:resource_name]

    all_pods.select do |q|
      (q["scope"] || q[:scope]) == scope &&
        (q["resource_name"] || q[:resource_name]) == resource
    end
  end

  # all_pods — full pod list from /pods (compact, no `?detail=true`
  # so we don't pay the inspect cost for the scope picker). Cached
  # by Rails.cache via the wrapper.
  def all_pods
    @all_pods ||= begin
      payload = Rails.cache.fetch(pods_cache_key, expires_in: 30.seconds) do
        @client.pods(detail: false)
      end

      Array(payload && payload["pods"])
    rescue Voodu::Client::Error => e
      Rails.logger.warn("metrics_page: pods fetch: #{e.class} #{e.message}")
      []
    end
  end

  private

  # chart_specs — per-scope metric layout. The `scale` key tells
  # fetch_points how to convert raw bytes → display unit so the
  # chart's axis labels, headline, and tooltip all speak the same
  # dialect (e.g. "GB" instead of "1233612800 B labeled as GB").
  #
  # Scales:
  #   :percent      — value as-is, formatted "12.4%"
  #   :bytes_to_mb  — divide by 1_000_000 (decimal MB, docker conv.)
  #   :bytes_to_gb  — divide by 1_000_000_000
  #   :bytes_auto   — pick B / kB / MB / GB based on magnitude
  def chart_specs
    if @scope_kind == "host"
      [
        { label: "CPU",    metric: "cpu_percent",      color: "var(--voodu-accent)", unit: "%",  scale: :percent     },
        { label: "Memory", metric: "mem_used_bytes",   color: "var(--voodu-blue)",   unit: "GB", scale: :bytes_to_gb },
        { label: "Disk",   metric: "disk_used_bytes",  color: "var(--voodu-green)",  unit: "GB", scale: :bytes_to_gb }
      ]
    else
      [
        { label: "CPU",    metric: "cpu_percent",            color: "var(--voodu-accent)", unit: "%",  scale: :percent     },
        { label: "Memory", metric: "mem_usage_bytes",        color: "var(--voodu-blue)",   unit: "MB", scale: :bytes_to_mb },
        { label: "Net Rx", metric: "net_rx_delta_bytes",     color: "var(--voodu-green)",  unit: "",   scale: :bytes_auto  },
        { label: "Net Tx", metric: "net_tx_delta_bytes",     color: "var(--voodu-amber)",  unit: "",   scale: :bytes_auto  }
      ]
    end
  end

  # fetch_points — calls /metrics for one series + scales the raw
  # values per the chart_spec. Pod scope needs scope/name (and
  # container for per-replica filtering); host scope leaves them
  # blank so the controller's filter returns the host row.
  def fetch_points(metric, scale)
    raw_points =
      if @scope_kind == "pod"
        pod = pod_record
        scope = pod && (pod["scope"] || pod[:scope])
        name  = pod && (pod["resource_name"] || pod[:resource_name])

        @metrics.points_for(
          source: :pod,
          metric: metric,
          range:  @range,
          scope:  scope,
          name:   name,
          pod:    @scope_id   # replica-precise filter (container name)
        )
      else
        @metrics.points_for(source: :system, metric: metric, range: @range)
      end

    rescale_points(raw_points, scale)
  end

  # rescale_points — per-chart numeric normalisation. Bypasses
  # MetricsData's default per-metric formatter when we want a
  # specific unit (e.g. GB instead of auto-MB).
  def rescale_points(points, scale)
    return points if scale == :percent

    case scale
    when :bytes_to_mb
      points.map do |p|
        mb = p[:value].to_f / 1_000_000
        { ts: p[:ts], value: mb, formatted: format("%.1f MB", mb) }
      end
    when :bytes_to_gb
      points.map do |p|
        gb = p[:value].to_f / 1_000_000_000
        { ts: p[:ts], value: gb, formatted: format("%.1f GB", gb) }
      end
    when :bytes_auto
      max_b = points.map { |p| p[:value].to_f }.max || 0
      divisor, suffix = pick_byte_unit(max_b)

      points.map do |p|
        v = p[:value].to_f / divisor
        { ts: p[:ts], value: v, formatted: format("%.1f %s", v, suffix) }
      end
    else
      points
    end
  end

  # pick_byte_unit — chart-wide scale choice based on the max
  # value. Locks the WHOLE chart to one unit so axis labels stay
  # consistent (otherwise some ticks would be "120" and others
  # "1.2k" — confusing).
  def pick_byte_unit(max_b)
    return [1.0,            "B"]  if max_b < 1_000
    return [1_000.0,        "kB"] if max_b < 1_000_000
    return [1_000_000.0,    "MB"] if max_b < 1_000_000_000

    [1_000_000_000.0, "GB"]
  end

  def pods_cache_key
    "voodu:metrics_pods:v1:island:#{@island.id}"
  end
end
