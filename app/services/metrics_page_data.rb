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
    "1m"  => "1m",
    "5m"  => "5m",
    "15m" => "15m",
    "1h"  => "1h",
    "6h"  => "6h",
    "24h" => "24h",
    "7d"  => "7d",
    "30d" => "30d"
  }.freeze

  DEFAULT_RANGE = "1h"

  # INTERVALS — operator-selectable bucket sizes for the chart's
  # x-axis density. `auto` defers to MetricsWarehouse#autopick (range
  # / MAX_BUCKETS rounded up to a clean step). Explicit values let
  # the operator override — e.g. "last 1h at 1m buckets" gives 60
  # data points instead of auto's 15s (240 points).
  #
  # Keep in lockstep with MetricsWarehouse::INTERVAL_ALIASES keys +
  # the IntervalPicker dropdown options. Drift = picker rows that
  # roundtrip to "auto" silently.
  INTERVALS = %w[auto 1s 10s 15s 1m 5m 15m 30m 1h].freeze

  DEFAULT_INTERVAL = "auto"

  attr_reader :scope_kind, :scope_id, :range, :interval

  def initialize(client, island, scope_kind:, scope_id:, range:, interval: nil)
    @client     = client
    @island     = island
    @scope_kind = (scope_kind == "pod") ? "pod" : "host"
    @scope_id   = scope_id
    @range      = RANGES.key?(range) ? range : DEFAULT_RANGE
    @interval   = INTERVALS.include?(interval) ? interval : DEFAULT_INTERVAL

    @metrics = MetricsData.new(client, island)
  end

  # charts — array of `{label, color, unit, points}` ready for
  # ChartCard. Empty array when client is nil (no island selected).
  def charts
    return [] if @client.nil?

    chart_specs.map { |spec| build_chart(spec) { fetch_points(spec[:metric], spec[:scale]) } }
  end

  # http_charts — second chart grid rendered on the /metrics page
  # when the active pod scope is ingress-eligible (deployment with
  # ≥1 ingress sample recorded in the warehouse). Mirrors the
  # HTTP cards on the pod show page so the two surfaces speak the
  # same vocabulary — operator drilling from pod show → metrics
  # page sees the same four metrics, just rendered as full charts
  # instead of compact stat cards.
  #
  # Returns `[]` when not eligible OR when scope is "host" (system-
  # level HTTP metrics don't make sense — host doesn't serve HTTP).
  def http_charts
    return [] if @client.nil?
    return [] unless ingress_eligible?

    ingress_chart_specs.map { |spec| build_chart(spec) { fetch_ingress_points(spec[:metric], spec[:scale]) } }
  end

  # available_metric_specs — list of every metric the in-modal
  # MetricPicker can swap to, grouped by section. Hosts get the
  # 3 resource metrics only; pods get 4 resource + (when
  # ingress-eligible) 4 HTTP metrics. Drives the modal's
  # "switch metric without closing" dropdown.
  #
  # Shape: [ { label: "RESOURCE", specs: [spec, ...] }, ... ]
  # Each spec hash is the same one chart_specs / ingress_chart_specs
  # returns — label, color, unit, metric, scale — so the picker
  # can build the chart URL directly without lookup.
  def available_metric_specs
    sections = [{ label: "RESOURCE", specs: chart_specs }]
    sections << { label: "HTTP", specs: ingress_chart_specs } if ingress_eligible?
    sections
  end

  # single_chart — used by the /metrics/chart endpoint (the modal
  # body that opens when an operator clicks the maximize icon on a
  # ChartCard). Takes the same spec shape build_chart works with
  # internally, routes to the right fetch path (system/pod resource
  # vs ingress) based on the metric name, and returns the same
  # envelope shape `charts` / `http_charts` produce — so the modal
  # body can render via the same Components::Metrics::Chart with
  # zero special-casing.
  def single_chart(metric:, scale:, label:, color:, unit:)
    return nil if @client.nil?

    spec = { metric: metric, scale: scale, label: label, color: color, unit: unit }

    build_chart(spec) do
      if INGRESS_METRICS.include?(metric)
        fetch_ingress_points(metric, scale)
      else
        fetch_points(metric, scale)
      end
    end
  end

  # ingress_eligible? — true when the current pod scope has at
  # least one ingress sample in the warehouse. Same data-driven
  # check used by PodDetailData; duplicated here (5 lines) to
  # avoid coupling the two data services. If a third surface
  # eventually wants the same check, lift to a shared helper.
  def ingress_eligible?
    return false unless @scope_kind == "pod" && @scope_id.present?

    pod = pod_record
    return false if pod.nil?

    scope = pod["scope"] || pod[:scope]
    name  = pod["resource_name"] || pod[:resource_name]
    return false if scope.blank? || name.blank?

    MetricSample.where(
      tenant_id: @island.id,
      source:    "ingress",
      scope:     scope,
      name:      name
    ).any?
  rescue ActiveRecord::StatementInvalid
    false
  end

  # range_ms — duration in milliseconds for the chart's x-axis
  # math (it needs to know "where does the right edge land"
  # relative to now). Mirrors the inspiration's RANGES.ms.
  def range_ms
    case @range
    when "1m"  then 60 * 1000
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
    @all_pods ||= IslandPods.compact(@client, @island)
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
  #   :count        — integer count, no transform, formatted "1234"
  #   :ms           — milliseconds, no transform, formatted "12.5 ms"
  def chart_specs
    if @scope_kind == "host"
      [
        { label: "CPU",    metric: "cpu_percent",      color: "var(--voodu-accent)", unit: "%",  scale: :percent     },
        { label: "Memory", metric: "mem_used_bytes",   color: "var(--voodu-blue)",   unit: "GB", scale: :bytes_to_gb },
        { label: "Disk",   metric: "disk_used_bytes",  color: "var(--voodu-teal)",   unit: "GB", scale: :bytes_to_gb }
      ]
    else
      [
        { label: "CPU",    metric: "cpu_percent",            color: "var(--voodu-accent)", unit: "%",  scale: :percent     },
        { label: "Memory", metric: "mem_usage_bytes",        color: "var(--voodu-blue)",   unit: "MB", scale: :bytes_to_mb },
        { label: "Net Rx", metric: "net_rx_delta_bytes",     color: "var(--voodu-green)",  unit: "",   scale: :bytes_auto  },
        { label: "Net Tx", metric: "net_tx_delta_bytes",     color: "var(--voodu-indigo)", unit: "",   scale: :bytes_auto  }
      ]
    end
  end

  # ingress_chart_specs — HTTP metrics (4 charts) layered below
  # resource metrics when the pod has ingress samples. Order
  # mirrors the pod-show stat cards so the two surfaces are
  # cognitively interchangeable.
  #
  # Color rule: every metric has a UNIQUE color across the page.
  # 5xx Errors is ALWAYS red — same rule applies to any future
  # failure / error / dead-replica chart we add (memorise this).
  def ingress_chart_specs
    [
      { label: "Requests",    metric: "req_count",       color: "var(--voodu-orange)", unit: "",   scale: :count      },
      { label: "p95 Latency", metric: "latency_p95_ms",  color: "var(--voodu-amber)",  unit: "ms", scale: :ms         },
      { label: "5xx Errors",  metric: "req_5xx",         color: "var(--voodu-red)",    unit: "",   scale: :count      },
      { label: "Bytes Out",   metric: "bytes_out",       color: "var(--voodu-pink)",   unit: "",   scale: :bytes_auto }
    ]
  end

  # build_chart — shared envelope construction for the resource +
  # HTTP chart specs. Caller passes the spec and a block that
  # returns the (already-rescaled) points; we wrap them with the
  # unit + current value the ChartCard component expects.
  #
  # `metric`/`source`/`scale` are echoed back unchanged so the
  # ChartCard's maximize-into-modal button can hand them off to
  # /metrics/chart for the refetch (the modal needs to know
  # which series to re-pull at the new range, independent of
  # whatever was used to render the inline card).
  def build_chart(spec)
    points = yield

    unit = if spec[:scale] == :bytes_auto && points.any?
             points.first[:formatted].to_s.split(" ").last.to_s
           else
             spec[:unit]
           end

    {
      label:   spec[:label],
      color:   spec[:color],
      unit:    unit,
      points:  points,
      current: latest_scaled_for(spec),
      metric:  spec[:metric],
      source:  source_for(spec[:metric]),
      scale:   spec[:scale]
    }
  end

  # source_for — maps a metric name to its NDJSON source. Resource
  # metrics under host scope live in "system"; same metric under
  # pod scope lives in "pod"; ingress metrics always in "ingress".
  # Needed by the chart-expand endpoint to rebuild the right
  # MetricsData query when the operator opens the modal.
  def source_for(metric)
    return "ingress" if INGRESS_METRICS.include?(metric)

    @scope_kind == "host" ? "system" : "pod"
  end

  # latest_scaled_for — dispatches to the right source (system / pod
  # / ingress) based on the spec's metric. The metric name uniquely
  # identifies its source (resource metrics live under system/pod,
  # ingress metrics under "ingress"), so we use a single lookup.
  def latest_scaled_for(spec)
    metric = spec[:metric]
    scale  = spec[:scale]

    if INGRESS_METRICS.include?(metric)
      latest_ingress_scaled(metric, scale)
    else
      latest_scaled(metric, scale)
    end
  end

  # INGRESS_METRICS — closed set of metric names known to live
  # under source="ingress". Used to route latest_scaled_for to the
  # right backend. Keep in sync with MetricsWarehouse::ALLOWED_METRICS
  # for ingress entries.
  INGRESS_METRICS = %w[
    req_count req_2xx req_3xx req_4xx req_5xx
    latency_p50_ms latency_p90_ms latency_p95_ms latency_p99_ms latency_max_ms
    bytes_out
  ].freeze

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
          source:   :pod,
          metric:   metric,
          range:    @range,
          interval: @interval,
          scope:    scope,
          name:     name,
          pod:      @scope_id   # replica-precise filter (container name)
        )
      else
        @metrics.points_for(source: :system, metric: metric, range: @range, interval: @interval)
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
    when :count
      # Integer counters (req_count, req_5xx, …). No transform on
      # the numeric value but format as int (so "184" not "184.0").
      points.map do |p|
        n = p[:value].to_f
        { ts: p[:ts], value: n, formatted: n.to_i.to_s }
      end
    when :ms
      # Latency in milliseconds — emitted in ms by the ingress
      # sampler, so no transform. Format with " ms" suffix.
      points.map do |p|
        v = p[:value].to_f
        { ts: p[:ts], value: v, formatted: format("%.1f ms", v) }
      end
    else
      points
    end
  end

  # fetch_ingress_points — parallel to fetch_points but routes to
  # source="ingress" with (scope, name) keying (no per-replica
  # filter — see ~/.claude/plans/voodu-http-metrics-from-caddy.md
  # for why ingress aggregates per-deployment).
  def fetch_ingress_points(metric, scale)
    pod = pod_record
    return [] unless pod

    scope = pod["scope"] || pod[:scope]
    name  = pod["resource_name"] || pod[:resource_name]

    raw_points = @metrics.points_for(
      source:   :ingress,
      metric:   metric,
      range:    @range,
      interval: @interval,
      scope:    scope,
      name:     name
    )

    rescale_points(raw_points, scale)
  end

  # latest_ingress_scaled — same shape as latest_scaled but for
  # source="ingress". Counter/ms scales pass through unchanged
  # (the warehouse already stores them in the target unit).
  def latest_ingress_scaled(metric, scale)
    pod = pod_record
    return nil unless pod

    scope = pod["scope"] || pod[:scope]
    name  = pod["resource_name"] || pod[:resource_name]

    raw = @metrics.latest_for(
      source: :ingress,
      metric: metric,
      range:  @range,
      scope:  scope,
      name:   name
    )
    return nil if raw.nil?

    case scale
    when :count      then raw.to_i
    when :ms         then raw
    when :bytes_auto
      divisor, _ = pick_byte_unit(raw.abs)
      raw / divisor
    else raw
    end
  end

  # latest_scaled — fetches the API's `latest` (unaggregated current
  # raw value) and applies the same per-chart scale that points went
  # through. Returns nil when the API didn't ship a latest (cold
  # boot before first sample). ChartCard then falls back to
  # series.last for that one render.
  def latest_scaled(metric, scale)
    raw = if @scope_kind == "pod"
            pod = pod_record
            scope = pod && (pod["scope"] || pod[:scope])
            name  = pod && (pod["resource_name"] || pod[:resource_name])
            @metrics.latest_for(source: :pod, metric: metric, range: @range,
                                scope: scope, name: name, pod: @scope_id)
          else
            @metrics.latest_for(source: :system, metric: metric, range: @range)
          end

    return nil if raw.nil?

    case scale
    when :percent      then raw
    when :bytes_to_mb  then raw / 1_000_000.0
    when :bytes_to_gb  then raw / 1_000_000_000.0
    when :bytes_auto
      # Use the same divisor as the chart's first point's unit so
      # headline + axis labels speak the same dialect. Re-derive
      # via the max heuristic — cheap, deterministic.
      divisor, _ = pick_byte_unit(raw.abs)
      raw / divisor
    else raw
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

end
