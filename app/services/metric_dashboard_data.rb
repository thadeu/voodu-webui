# frozen_string_literal: true

# MetricDashboardData — the /metrics data object for DASHBOARD mode.
#
# Drop-in sibling of MetricsPageData: exposes the same `charts` /
# `http_charts` / `range` / `interval` / `range_ms` surface the
# Frame + Index views consume, so the chart grid renders unchanged.
# The difference is the source — instead of one scope's fixed metric
# layout, it renders the saved dashboard's arbitrary (source, metric)
# panels, each fetched via MetricsPageData#single_chart.
#
# Panel identity is workload-level for pods (`scope` + `name`); we
# resolve the current running replica's container id at render time,
# so a saved dashboard survives a redeploy. A workload with no live
# replica yields a `missing: true` placeholder card instead of a
# broken chart.
#
# Performance: N panels = N metric fetches (each cached 60s by
# MetricsData), same per-chart cost as today's scope page. Sequential
# for MVP; MetricDashboard::MAX_PANELS bounds the fan-out.
class MetricDashboardData
  attr_reader :dashboard, :range, :interval

  def initialize(client, island, dashboard, range:, interval: nil, from: nil, until_: nil)
    @client = client
    @island = island
    @dashboard = dashboard
    @range = MetricsPageData::RANGES.key?(range) ? range : MetricsPageData::DEFAULT_RANGE
    @interval = MetricsPageData::INTERVALS.include?(interval) ? interval : MetricsPageData::DEFAULT_INTERVAL
    @from = from
    @until_ = until_
  end

  def custom?
    @from.present? && @until_.present?
  end

  # dashboard? — lets the Index/Frame views branch their toolbar
  # without an is_a? check leaking the class name into the view.
  def dashboard?
    true
  end

  # ingress_eligible? — false: dashboards fold any HTTP panels the
  # operator chose directly into `charts`, so the views' "append
  # http_charts when ingress-eligible" branch must be a no-op here.
  def ingress_eligible?
    false
  end

  # display_kind — namespaces the metrics-display controller's
  # sessionStorage (hide/reorder) per-dashboard, so reordering one
  # dashboard's cards doesn't bleed into another's or into a scope view.
  def display_kind
    "dashboard:#{@dashboard&.id}"
  end

  def empty?
    @dashboard.nil? || panels.empty?
  end

  # charts — one envelope per panel (same shape as MetricsPageData),
  # in declared order. nil-safe: a fetch that comes back empty still
  # renders a (flat) chart; only an unresolvable workload becomes a
  # placeholder.
  def charts
    return [] if @client.nil? && !warehouse?
    return [] if @dashboard.nil?

    panels.each_with_index.map { |panel, i| chart_for(panel, i) }.compact
  end

  # http_charts — dashboards fold every panel into the single grid;
  # there is no separate HTTP section. Empty so the shared views that
  # call http_charts on the scope path degrade cleanly.
  def http_charts
    []
  end

  def range_ms
    return scope_page.range_ms if custom?

    MetricsPageData.range_to_ms(@range)
  end

  # scope_page — a throwaway MetricsPageData carrying this dashboard's range +
  # custom window, used to reuse its custom_window_ms math for range_ms.
  def scope_page
    @scope_page ||= MetricsPageData.new(
      @client, @island, scope_kind: "host", scope_id: nil,
      range: @range, interval: @interval, from: @from, until_: @until_
    )
  end

  # pods — the compact pod list, fetched once and shared across every
  # panel's workload→replica resolution.
  def pods
    @pods ||= IslandPods.compact(@client, @island)
  end

  private

  def panels
    Array(@dashboard&.panels)
  end

  def warehouse?
    defined?(IslandState) && IslandState.warehouse?
  end

  # chart_for — resolve the panel's scope, then reuse
  # MetricsPageData#single_chart for the fetch + scale + capacity.
  # Merges scope_kind/scope_id back so the ChartCard maximize button
  # can build its /metrics/chart expand URL for the right series.
  def chart_for(panel, index)
    key = MetricDashboard.panel_card_key(index)

    return log_chart_for(panel, key) if panel["scope_kind"].to_s == "log"

    if panel["scope_kind"].to_s == "pod"
      scope_id = resolve_container(panel)
      return missing_card(panel, key) if scope_id.nil?

      scope_kind = "pod"
    else
      scope_kind = "host"
      scope_id = nil
    end

    page = MetricsPageData.new(
      @client, @island,
      scope_kind: scope_kind, scope_id: scope_id,
      range: @range, interval: @interval, from: @from, until_: @until_
    )

    chart = page.single_chart(
      metric: panel["metric"].to_s,
      scale: panel["scale"].presence&.to_sym,
      label: panel["label"].to_s,
      color: panel["color"].to_s,
      unit: panel["unit"].to_s,
      chart_type: panel["chart_type"].presence || :area
    )
    return missing_card(panel, key) if chart.nil?

    # scope_kind/scope_id → so the ChartCard maximize button can build
    # the right /metrics/chart expand URL. default_visible: true → the
    # operator explicitly chose every panel, so never let the
    # metrics-display "hide picker-only HTTP metrics on first run"
    # heuristic hide one (an HTTP metric carries default_visible: false
    # from its spec). panel_key → the unique data-metric-key the
    # Settings/Order drawer toggles + reorders this panel by.
    chart.merge(scope_kind: scope_kind, scope_id: scope_id,
      default_visible: true, panel_key: key)
  end

  # log_chart_for — a log-count panel: read the filter's pre-aggregated count
  # series (via LogMetricData) and reduce it per the query's `| agg` suffix,
  # returned as a `number` envelope the NumberCard renders. The series is
  # bucketed by the dashboard interval (so the sparkline honours the picker).
  #
  # default_visible: true — the operator explicitly chose this panel, so the
  # metrics-display "hide picker-only on first run" heuristic must never hide
  # it. panel_key → the data-metric-key the Settings/Order drawer toggles by.
  def log_chart_for(panel, key)
    data = LogMetricData.new(
      @island,
      query: panel["query"].to_s,
      range: @range,
      interval: @interval,
      scope: panel["scope"].to_s,
      name: panel["name"].to_s,
      from: @from,
      until_: @until_
    )

    # show_chart — the operator's per-panel toggle: a count tile can be just the
    # big number (show_chart false) or number + timeline area chart (true).
    # Series is only computed/passed when the chart is wanted; an empty series
    # makes the NumberCard render the number alone. Absent key → true, so legacy
    # panels keep their chart.
    {
      kind: :number,
      label: panel["label"].to_s,
      color: panel["color"].to_s,
      value: data.value,
      formatted: data.formatted,
      series: show_chart?(panel) ? data.series : [],
      meta: data.meta,
      clamped: data.clamped?,
      range: @range,
      range_ms: range_ms,
      default_visible: true,
      panel_key: key
    }
  end

  # show_chart? — whether a log-count panel wants its timeline chart. Defaults
  # to true (absent key = legacy panel = keep the chart). Coerces the stored
  # value robustly: the builder writes a real JSON boolean, but a hand-edited
  # row might carry "false"/"0" — ActiveModel's boolean cast handles both.
  def show_chart?(panel)
    raw = panel["show_chart"]
    return true if raw.nil?

    ActiveModel::Type::Boolean.new.cast(raw)
  end

  # resolve_container — workload (scope + resource_name) → the current
  # replica's container name. Prefers a running replica; falls back to
  # the first match of any status; nil when the workload has no pod
  # right now (scaled to zero, deleted, mid-redeploy gap).
  def resolve_container(panel)
    scope = panel["scope"].to_s
    name = panel["name"].to_s

    matches = pods.select do |p|
      field(p, "scope") == scope && field(p, "resource_name") == name
    end
    return nil if matches.empty?

    running = matches.find { |p| field(p, "status") == "running" }
    field(running || matches.first, "name").presence
  end

  # missing_card — placeholder envelope for an unresolvable workload.
  # The Frame renders a muted "no running replica" tile from `missing`.
  def missing_card(panel, key)
    {
      label: panel["label"].to_s,
      color: panel["color"].to_s,
      missing: true,
      source_label: (panel["scope_kind"].to_s == "host") ? "host" : panel["scope"].to_s,
      metric: panel["metric"].to_s,
      panel_key: key
    }
  end

  # field — read a key from a pod hash that may use string OR symbol
  # keys (IslandPods.compact returns string-keyed in warehouse mode,
  # and the live path mirrors it — but be defensive).
  def field(pod, key)
    return "" if pod.nil?

    (pod[key] || pod[key.to_sym]).to_s
  end
end
