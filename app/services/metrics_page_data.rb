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
    "1m" => "1m",
    "5m" => "5m",
    "15m" => "15m",
    "1h" => "1h",
    "6h" => "6h",
    "24h" => "24h",
    "7d" => "7d",
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

  # display_kind — the key used to namespace display-settings in
  # sessionStorage. "host" for the system scope; for pod scopes,
  # the pod's workload kind ("deployment", "statefulset", etc.).
  # Falls back to "pod" when the pod record is unavailable (e.g.
  # the pod just terminated between page loads).
  def display_kind
    return "host" if @scope_kind == "host"

    pod = pod_record
    return "pod" if pod.nil?

    (pod["kind"] || pod[:kind]).to_s.presence || "pod"
  end

  # dashboard? — false. Sibling MetricDashboardData returns true so the
  # /metrics views branch their toolbar without an is_a? check.
  def dashboard?
    false
  end

  def initialize(client, island, scope_kind:, scope_id:, range:, interval: nil)
    @client = client
    @island = island
    @scope_kind = (scope_kind == "pod") ? "pod" : "host"
    @scope_id = scope_id
    @range = RANGES.key?(range) ? range : DEFAULT_RANGE
    @interval = INTERVALS.include?(interval) ? interval : DEFAULT_INTERVAL

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

    # Emit ALL picker specs (8 cards) so the operator can un-hide any
    # of the latency / status-code variants via the Settings drawer.
    # Each card carries `default_visible: true|false` — JS hides the
    # picker-only ones on first run for a kind that hasn't been
    # configured yet (~4 visible by default, ~4 in the Latency/Errors
    # group pickers).
    ingress_picker_specs.map { |spec| build_chart(spec) { fetch_ingress_points(spec[:metric], spec[:scale]) } }
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
    sections = [{label: "RESOURCE", specs: chart_specs}]
    sections << {label: "HTTP", specs: ingress_picker_specs} if ingress_eligible?
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
  def single_chart(metric:, scale:, label:, color:, unit:, chart_type: :area)
    return nil if @client.nil?

    spec = {metric: metric, scale: scale, label: label, color: color, unit: unit, chart_type: chart_type}

    build_chart(spec) do
      if INGRESS_METRICS.include?(metric)
        fetch_ingress_points(metric, scale)
      else
        fetch_points(metric, scale)
      end
    end
  end

  # ingress_eligible? — true when the current pod scope is a
  # `kind=deployment`. KIND-DRIVEN, not data-driven: a brand-new
  # deployment that hasn't received a request yet still shows the
  # HTTP section, just with heartbeat-zero charts. Operator sees
  # the surface exists from day one instead of "waiting for HTTP
  # cards to appear" once traffic starts.
  #
  # Trade-off accepted: a deployment without an ingress declared
  # will render the HTTP cards as flat-zero forever (the ingress
  # sampler only emits heartbeat rows for KNOWN bindings). That's
  # a visible signal too — "you've got a deployment with no
  # ingress mapped; declare one to start receiving HTTP signals"
  # — and more honest than hiding the cards and leaving the
  # operator wondering whether HTTP metrics exist at all.
  #
  # Statefulsets, jobs, cronjobs return false: they don't serve
  # HTTP, so showing zero-HTTP charts on them would be noise.
  def ingress_eligible?
    return false unless @scope_kind == "pod" && @scope_id.present?

    pod = pod_record
    return false if pod.nil?

    kind = (pod["kind"] || pod[:kind]).to_s
    kind == "deployment"
  end

  # range_ms — duration in milliseconds for the chart's x-axis
  # math (it needs to know "where does the right edge land"
  # relative to now). Mirrors the inspiration's RANGES.ms.
  def range_ms
    self.class.range_to_ms(@range)
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

    scope = p["scope"] || p[:scope]
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

  # ── Class-level spec accessors (used by /metrics/display_settings) ──

  # resource_specs_for — static spec list for the given scope_kind.
  # Mirrors chart_specs instance method; kept as a class method so
  # the display_settings endpoint can build spec cards without
  # instantiating a full MetricsPageData (which needs a live client).
  # All entries carry section: "resource".
  #
  # Each spec carries `scale` (matching the instance `chart_specs`)
  # so catalog consumers — the dashboard builder + MetricDashboardData —
  # capture a fully self-contained panel: metric + scale + label/color/
  # unit, ready to hand straight to single_chart with no lookup.
  def self.resource_specs_for(scope_kind)
    base =
      if scope_kind == "host"
        [
          {label: "CPU", metric: "cpu_percent", color: "var(--voodu-purple)", unit: "%", scale: :percent},
          {label: "Memory", metric: "mem_used_bytes", color: "var(--voodu-blue)", unit: "GB", scale: :bytes_to_gb},
          {label: "Disk", metric: "disk_used_bytes", color: "var(--voodu-teal)", unit: "GB", scale: :bytes_to_gb}
        ]
      else
        [
          {label: "CPU", metric: "cpu_percent", color: "var(--voodu-purple)", unit: "%", scale: :percent},
          {label: "Memory", metric: "mem_usage_bytes", color: "var(--voodu-blue)", unit: "MB", scale: :bytes_to_mb},
          {label: "Net Rx", metric: "net_rx_delta_bytes", color: "var(--voodu-green)", unit: "", scale: :bytes_auto},
          {label: "Net Tx", metric: "net_tx_delta_bytes", color: "var(--voodu-indigo)", unit: "", scale: :bytes_auto}
        ]
      end

    base.map { |s| s.merge(section: "resource") }
  end

  # http_specs_static — the FULL HTTP set (8 metrics) used by the
  # display_settings endpoint. The view groups the latency variants
  # (p90/p95/p99) into a "Latency" picker card and the status code
  # variants (3xx/4xx/5xx) into an "Errors" picker card so the
  # drawer stays compact regardless of how many percentile / status
  # variants we eventually expose.
  #
  # default_visible mirrors the chart-grid behavior: p95 + 5xx are
  # the canonical "primary" variants and stay visible on first run;
  # p90, p99, 3xx, 4xx default hidden and only appear when operator
  # checks them in the group picker.
  def self.http_specs_static
    [
      {label: "Requests", metric: "req_count", color: "var(--voodu-orange)", unit: "", scale: :count, section: "http", default_visible: true},
      {label: "p90 Latency", metric: "latency_p90_ms", color: "var(--voodu-gold)", unit: "ms", scale: :ms, section: "http", default_visible: false},
      {label: "p95 Latency", metric: "latency_p95_ms", color: "var(--voodu-amber)", unit: "ms", scale: :ms, section: "http", default_visible: true},
      {label: "p99 Latency", metric: "latency_p99_ms", color: "var(--voodu-violet)", unit: "ms", scale: :ms, section: "http", default_visible: false},
      {label: "3xx", metric: "req_3xx", color: "var(--voodu-sky)", unit: "", scale: :count, section: "http", default_visible: false},
      {label: "4xx", metric: "req_4xx", color: "var(--voodu-rose)", unit: "", scale: :count, section: "http", default_visible: false},
      {label: "5xx Errors", metric: "req_5xx", color: "var(--voodu-red)", unit: "", scale: :count, section: "http", default_visible: true},
      {label: "Bytes Out", metric: "bytes_out", color: "var(--voodu-pink)", unit: "", scale: :bytes_auto, section: "http", default_visible: true}
    ]
  end

  # metric_catalog_for — the metrics a given source exposes, with full
  # specs (incl. scale). Drives the dashboard builder's metric dropdown
  # and MetricDashboardData. `kind` is the pod's workload kind (only
  # "deployment" pods expose the HTTP family); ignored for host.
  #
  #   metric_catalog_for("host", nil)          → 3 host resource metrics
  #   metric_catalog_for("pod",  "deployment") → 4 resource + 8 HTTP
  #   metric_catalog_for("pod",  "statefulset")→ 4 resource
  def self.metric_catalog_for(scope_kind, kind = nil)
    specs = resource_specs_for(scope_kind)
    specs += http_specs_static if scope_kind == "pod" && kind.to_s == "deployment"

    specs
  end

  # range_to_ms — range id → milliseconds. Class method so both the
  # instance `range_ms` and MetricDashboardData share one mapping.
  def self.range_to_ms(range)
    case range
    when "1m" then 60 * 1000
    when "5m" then 5 * 60 * 1000
    when "15m" then 15 * 60 * 1000
    when "1h" then 60 * 60 * 1000
    when "6h" then 6 * 60 * 60 * 1000
    when "24h" then 24 * 60 * 60 * 1000
    when "7d" then 7 * 24 * 60 * 60 * 1000
    when "30d" then 30 * 24 * 60 * 60 * 1000
    else 60 * 60 * 1000
    end
  end

  # display_settings_items_for — what the Settings drawer renders.
  # Resource metrics stay as single tiles; HTTP latency + error
  # variants get grouped into picker cards so the drawer doesn't
  # balloon. Returns a flat array of items, each either:
  #   { kind: :single, ... spec fields }
  #   { kind: :group,  label:, group_key:, color:, unit:, section:, members: [specs] }
  #
  # The view renders single → normal tile; group → expandable tile
  # with sub-metric checkboxes inside.
  def self.display_settings_items_for(scope_kind, kind)
    items = resource_specs_for(scope_kind).map { |s| s.merge(kind: :single) }

    return items unless kind == "deployment"

    http = http_specs_static.each_with_object({}) { |s, h| h[s[:metric]] = s }

    # Layout: Requests → Latency group → Errors group → Bytes Out
    items << http["req_count"].merge(kind: :single)

    items << {
      kind: :group,
      label: "Latency",
      group_key: "latency",
      color: "var(--voodu-amber)",
      unit: "ms",
      section: "http",
      members: [http["latency_p90_ms"], http["latency_p95_ms"], http["latency_p99_ms"]]
    }

    items << {
      kind: :group,
      label: "Errors",
      group_key: "errors",
      color: "var(--voodu-red)",
      unit: "",
      section: "http",
      members: [http["req_3xx"], http["req_4xx"], http["req_5xx"]]
    }

    items << http["bytes_out"].merge(kind: :single)

    items
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
        {label: "CPU", metric: "cpu_percent", color: "var(--voodu-purple)", unit: "%", scale: :percent},
        {label: "Memory", metric: "mem_used_bytes", color: "var(--voodu-blue)", unit: "GB", scale: :bytes_to_gb},
        {label: "Disk", metric: "disk_used_bytes", color: "var(--voodu-teal)", unit: "GB", scale: :bytes_to_gb, chart_type: :gauge_radial}
      ]
    else
      [
        {label: "CPU", metric: "cpu_percent", color: "var(--voodu-purple)", unit: "%", scale: :percent},
        {label: "Memory", metric: "mem_usage_bytes", color: "var(--voodu-blue)", unit: "MB", scale: :bytes_to_mb},
        {label: "Net Rx", metric: "net_rx_delta_bytes", color: "var(--voodu-green)", unit: "", scale: :bytes_auto},
        {label: "Net Tx", metric: "net_tx_delta_bytes", color: "var(--voodu-indigo)", unit: "", scale: :bytes_auto}
      ]
    end
  end

  # ingress_chart_specs — HTTP metrics RENDERED AS CARDS on the
  # page grid (and the modal's inline grid). Intentionally narrow:
  # 4 "default view" signals an operator wants at a glance. The
  # rest of the HTTP family lives in `ingress_picker_only_specs`
  # and is only reachable via the modal's metric picker — keeps
  # the page from drowning under 8 charts while still letting an
  # operator drill into p99 / 4xx / 3xx on demand.
  #
  # Color rule: every metric has a UNIQUE color across the page.
  # 5xx Errors is ALWAYS red — same rule applies to any future
  # failure / error / dead-replica chart we add (memorise this).
  def ingress_chart_specs
    [
      {label: "Requests", metric: "req_count", color: "var(--voodu-orange)", unit: "", scale: :count, default_visible: true},
      {label: "p95 Latency", metric: "latency_p95_ms", color: "var(--voodu-amber)", unit: "ms", scale: :ms, default_visible: true},
      {label: "5xx Errors", metric: "req_5xx", color: "var(--voodu-red)", unit: "", scale: :count, default_visible: true},
      {label: "Bytes Out", metric: "bytes_out", color: "var(--voodu-pink)", unit: "", scale: :bytes_auto, default_visible: true}
    ]
  end

  # ingress_picker_only_specs — HTTP metrics available IN THE
  # PICKER but NOT rendered as cards on the grid. Operator opens
  # the modal on any card, then swaps to p90 / p99 / 3xx / 4xx
  # via the dropdown — same single-chart endpoint, just a
  # different metric.
  #
  # Color assignments follow the palette rule (1 metric = 1
  # color, red family = errors). See theme.css for the full
  # rationale on gold/violet/sky/rose.
  def ingress_picker_only_specs
    [
      {label: "p90 Latency", metric: "latency_p90_ms", color: "var(--voodu-gold)", unit: "ms", scale: :ms, default_visible: false},
      {label: "p99 Latency", metric: "latency_p99_ms", color: "var(--voodu-violet)", unit: "ms", scale: :ms, default_visible: false},
      {label: "3xx", metric: "req_3xx", color: "var(--voodu-sky)", unit: "", scale: :count, default_visible: false},
      {label: "4xx", metric: "req_4xx", color: "var(--voodu-rose)", unit: "", scale: :count, default_visible: false}
    ]
  end

  # ingress_picker_specs — full HTTP set exposed to the modal's
  # metric picker. Order: Requests → latency family (p90/p95/p99)
  # → status codes ascending (3xx/4xx/5xx) → Bytes Out. Reads
  # like a natural left-to-right "what happened" narrative:
  # volume, speed, outcome, bandwidth.
  def ingress_picker_specs
    chart = ingress_chart_specs.each_with_object({}) { |s, h| h[s[:metric]] = s }
    extra = ingress_picker_only_specs.each_with_object({}) { |s, h| h[s[:metric]] = s }
    by_metric = chart.merge(extra)

    %w[
      req_count
      latency_p90_ms latency_p95_ms latency_p99_ms
      req_3xx req_4xx req_5xx
      bytes_out
    ].map { |m| by_metric[m] }.compact
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
    src = source_for(spec[:metric])
    cap = capacity_for(spec)

    unit = if spec[:scale] == :bytes_auto && points.any?
      points.first[:formatted].to_s.split(" ").last.to_s
    else
      spec[:unit]
    end

    {
      label: spec[:label],
      color: spec[:color],
      unit: unit,
      points: points,
      current: latest_scaled_for(spec),
      metric: spec[:metric],
      source: src,
      # section — "resource" for system/pod cards, "http" for ingress.
      # Drives the inline [http] badge on the chart card label and
      # the `data-section` attribute that lets the metrics-display
      # controller route saved hide-state to the right bucket.
      section: (src == "ingress") ? "http" : "resource",
      scale: spec[:scale],
      # default_visible — false for picker-only metrics (p90, p99,
      # 3xx, 4xx). When the operator hasn't configured display
      # settings for this kind yet, JS hides cards with
      # default_visible: false on first connect.
      default_visible: spec.fetch(:default_visible, true),
      # capacity_label / capacity_pct — "X GB / Y GB · Z%" context
      # rendered next to the current value on memory + disk cards
      # (host or pod) so the operator reads "21.9 GB of 39 GB · 56%"
      # like they do on Overview. nil for CPU (no natural total) and
      # for HTTP/Net metrics (no fixed cap). See `capacity_for`.
      capacity_label: cap && cap[:label],
      capacity_pct: cap && cap[:pct],
      # chart_type — "area" (default) | "gauge_radial" | "gauge_linear".
      # Carried from the spec so ChartCard picks the right body.
      chart_type: spec.fetch(:chart_type, :area)
    }
  end

  # capacity_for — resolves the "of Y" total to pair with the current
  # value for a given metric. Returns `{ label:, pct: }` when the
  # metric has a meaningful total, nil otherwise.
  #
  # Logic:
  #   host scope:
  #     mem_used_bytes  → host total memory (from system snapshot)
  #     disk_used_bytes → host total disk space (system snapshot)
  #     cpu_percent     → nil (% has no "of N cores" pairing that
  #                       reads better than the % alone)
  #
  #   pod scope:
  #     mem_usage_bytes → container memory_limit_bytes from the pod
  #                       stats. Skipped when the value is huge (no
  #                       explicit limit → docker reports kernel max)
  #                       since "23 MB of 9223372036 GB" is noise.
  #     cpu_percent     → nil for the same reason as host CPU
  #     net_*           → nil (no fixed cap)
  #
  # The label uses the SAME scale as the chart's headline so units
  # line up ("0.9 GB / 4 GB" not "950 MB / 4 GB").
  def capacity_for(spec)
    return nil if spec[:scale] == :percent
    return nil if INGRESS_METRICS.include?(spec[:metric])

    if @scope_kind == "host"
      capacity_for_host(spec)
    else
      capacity_for_pod(spec)
    end
  end

  # capacity_for_host — host total memory / disk, sourced from the
  # latest system snapshot. Reuses the warehouse path so this is a
  # single SQLite read in warehouse mode; falls back to a live
  # /system HTTP call when warehouse mode is off.
  def capacity_for_host(spec)
    case spec[:metric]
    when "mem_used_bytes"
      total = host_system_payload&.dig("mem", "total_bytes").to_i
      build_capacity(spec, total)
    when "disk_used_bytes"
      total = host_system_payload&.dig("disk", 0, "total_bytes").to_i
      build_capacity(spec, total)
    end
  end

  # capacity_for_pod — container memory limit from the pod's stats
  # block. Docker reports a kernel-max value (~9.2 EiB) when no
  # explicit `resources.limits.memory` is declared in the manifest;
  # we skip the badge in that case rather than render confusing
  # "23 MB of 9223372036 GB" arithmetic.
  def capacity_for_pod(spec)
    return nil unless spec[:metric] == "mem_usage_bytes"

    pod = pod_record
    return nil if pod.nil?

    limit = pod.dig("stats", "usage", "memory_limit_bytes").to_i
    # 1 TiB threshold — well above any single-container limit anyone
    # configures intentionally, well below the kernel-max sentinel
    # docker returns when no limit was set.
    return nil if limit <= 0 || limit > 1_099_511_627_776

    build_capacity(spec, limit)
  end

  # build_capacity — turns a raw bytes total into the `{ label, pct }`
  # shape the chart card expects. `pct` is computed against the
  # latest sample (same value the headline shows), so the percentage
  # and current always agree.
  def build_capacity(spec, total_bytes)
    return nil if total_bytes <= 0

    scaled_total = rescale_value(total_bytes, spec[:scale])
    unit = spec[:unit]

    label = format("%s %s", format_capacity_number(scaled_total), unit).strip

    current = latest_scaled_for(spec)
    pct =
      if current && total_bytes.positive?
        # Convert current back to bytes for the ratio. We could use
        # scaled_total too — same answer either way (ratio is
        # scale-invariant) — but raw-bytes math avoids float drift
        # at the GB/MB boundary.
        current_bytes = unscale_value(current, spec[:scale])
        (current_bytes.to_f / total_bytes * 100).round
      end

    {label: label, pct: pct}
  end

  # rescale_value — bytes → display-unit number, matching the same
  # transform `rescale_points` applies to the series. Pulled out so
  # build_capacity can scale the TOTAL using the same dialect as the
  # chart headline.
  def rescale_value(bytes, scale)
    case scale
    when :bytes_to_mb then bytes / 1_000_000.0
    when :bytes_to_gb then bytes / 1_000_000_000.0
    when :bytes_auto
      divisor, _ = pick_byte_unit(bytes.abs)
      bytes / divisor
    else bytes
    end
  end

  # unscale_value — display-unit number → bytes. Inverse of
  # rescale_value so build_capacity can recover the absolute bytes
  # of the current sample (already rescaled by the time we read it)
  # for the percentage math.
  def unscale_value(value, scale)
    case scale
    when :bytes_to_mb then value * 1_000_000
    when :bytes_to_gb then value * 1_000_000_000
    else value
    end
  end

  # format_capacity_number — capacity totals are usually whole or
  # near-whole numbers (39 GB, 512 MB). Trim to 1 decimal place but
  # drop the .0 suffix so "39 GB" reads as "39 GB" not "39.0 GB".
  def format_capacity_number(v)
    n = v.to_f
    return n.to_i.to_s if n == n.to_i

    format("%.1f", n)
  end

  # host_system_payload — system info for the current island. In
  # warehouse mode this is a sub-millisecond local read off the
  # latest StateSyncIslandJob snapshot; in HTTP mode it falls back
  # to a live /system call. Memoised per-instance so multiple
  # capacity lookups don't re-hit the source.
  def host_system_payload
    return @host_system_payload if defined?(@host_system_payload)

    @host_system_payload =
      if defined?(IslandState) && IslandState.warehouse?
        IslandState.for(@island)&.system
      else
        @client&.system
      end
  end

  # source_for — maps a metric name to its NDJSON source. Resource
  # metrics under host scope live in "system"; same metric under
  # pod scope lives in "pod"; ingress metrics always in "ingress".
  # Needed by the chart-expand endpoint to rebuild the right
  # MetricsData query when the operator opens the modal.
  def source_for(metric)
    return "ingress" if INGRESS_METRICS.include?(metric)

    (@scope_kind == "host") ? "system" : "pod"
  end

  # latest_scaled_for — dispatches to the right source (system / pod
  # / ingress) based on the spec's metric. The metric name uniquely
  # identifies its source (resource metrics live under system/pod,
  # ingress metrics under "ingress"), so we use a single lookup.
  def latest_scaled_for(spec)
    metric = spec[:metric]
    scale = spec[:scale]

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
        name = pod && (pod["resource_name"] || pod[:resource_name])

        @metrics.points_for(
          source: :pod,
          metric: metric,
          range: @range,
          interval: @interval,
          scope: scope,
          name: name,
          pod: @scope_id   # replica-precise filter (container name)
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
        {ts: p[:ts], value: mb, formatted: format("%.1f MB", mb)}
      end
    when :bytes_to_gb
      points.map do |p|
        gb = p[:value].to_f / 1_000_000_000
        {ts: p[:ts], value: gb, formatted: format("%.1f GB", gb)}
      end
    when :bytes_auto
      max_b = points.map { |p| p[:value].to_f }.max || 0
      divisor, suffix = pick_byte_unit(max_b)

      points.map do |p|
        v = p[:value].to_f / divisor
        {ts: p[:ts], value: v, formatted: format("%.1f %s", v, suffix)}
      end
    when :count
      # Integer counters (req_count, req_5xx, …). No transform on
      # the numeric value but format as int (so "184" not "184.0").
      points.map do |p|
        n = p[:value].to_f
        {ts: p[:ts], value: n, formatted: n.to_i.to_s}
      end
    when :ms
      # Latency in milliseconds — emitted in ms by the ingress
      # sampler, so no transform. Format with " ms" suffix.
      points.map do |p|
        v = p[:value].to_f
        {ts: p[:ts], value: v, formatted: format("%.1f ms", v)}
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
    name = pod["resource_name"] || pod[:resource_name]

    raw_points = @metrics.points_for(
      source: :ingress,
      metric: metric,
      range: @range,
      interval: @interval,
      scope: scope,
      name: name
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
    name = pod["resource_name"] || pod[:resource_name]

    raw = @metrics.latest_for(
      source: :ingress,
      metric: metric,
      range: @range,
      scope: scope,
      name: name
    )
    return nil if raw.nil?

    case scale
    when :count then raw.to_i
    when :ms then raw
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
      name = pod && (pod["resource_name"] || pod[:resource_name])
      @metrics.latest_for(source: :pod, metric: metric, range: @range,
        scope: scope, name: name, pod: @scope_id)
    else
      @metrics.latest_for(source: :system, metric: metric, range: @range)
    end

    return nil if raw.nil?

    case scale
    when :percent then raw
    when :bytes_to_mb then raw / 1_000_000.0
    when :bytes_to_gb then raw / 1_000_000_000.0
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
    return [1.0, "B"] if max_b < 1_000
    return [1_000.0, "kB"] if max_b < 1_000_000
    return [1_000_000.0, "MB"] if max_b < 1_000_000_000

    [1_000_000_000.0, "GB"]
  end
end
