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

    if panel["scope_kind"].to_s == "table"
      # A "table" panel is DataTable-family: chart_type "table" → rows;
      # anything else (area/radial/linear) → a HEP3 count chart.
      return (panel["chart_type"].to_s == "table") ? table_chart_for(panel, key) : hep_chart_for(panel, key)
    end

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

  # table_chart_for — a Table panel: a DataSource-backed data table. No
  # server-side row fetch — the DataTable Stimulus controller pulls rows
  # from /metrics/datatable/:source/rows (filter / paging / live-append
  # cursors in the query string), so the dashboard frame reload stays
  # cheap and the table keeps its own client state (scroll, pause). The
  # envelope just carries what the card needs to wire that controller.
  #
  # default_visible: true — the operator chose this panel; panel_key → the
  # data-metric-key the Settings/Order drawer toggles + reorders it by.
  # hep_chart_for — a HEP3 source rendered as a chart: the per-bucket COUNT of
  # the view (messages/calls/errors, matching the filter) becomes a sparkline.
  #   number → a big-number tile (the range TOTAL) + sparkline [NumberCard]
  #   area   → area chart, headline = the range TOTAL                [ChartCard]
  #   gauge  → latest bucket against the range PEAK (Thadeu's "vs pico")
  def hep_chart_for(panel, key)
    source = DataTable::Registry.build(
      panel["source"], island: @island, params: {scope: panel["scope"], name: panel["name"]}
    )
    chart_type = panel["chart_type"].presence || "area"
    view = panel["view"].presence || "messages"
    from, to = hep_window
    bucket = hep_bucket_seconds

    series = source ? source.count_series(view: view, filter_query: panel["filter_query"].to_s, ts_from: from, ts_to: to, bucket: bucket) : []
    points = hep_points(series, from, to, bucket)
    values = points.map { |p| p[:value] }
    total = values.sum
    peak = values.max.to_i

    # Number tile — the TOTAL over the range + the sparkline. No confusing
    # "vs peak %"; the natural read for a count (mirrors the log-count tile).
    if chart_type == "number"
      return {
        kind: :number, label: panel["label"].to_s, color: panel["color"].to_s,
        formatted: total.to_s, value: total, series: points,
        range: @range, range_ms: range_ms, truncated: false, clamped: false, meta: nil,
        default_visible: true, panel_key: key
      }
    end

    # Gauge — the value is the range TOTAL too, so all shapes of the same panel
    # read the SAME number (Area/Number/Gauge = 7, not "7 vs 0/1"). The arc is
    # the average bucket relative to the peak bucket (how busy vs the busiest
    # moment); no sub-label (the footer already carries min/avg/max).
    gauge = %w[gauge_radial gauge_linear].include?(chart_type)
    avg = points.empty? ? 0.0 : (total.to_f / points.size)
    cap = if gauge
      {label: nil, pct: (peak.positive? ? ((avg / peak) * 100).round : 0)}
    end

    {
      label: panel["label"].to_s,
      color: panel["color"].to_s,
      unit: "",
      points: points,
      current: total,
      metric: key,
      source: "hep3",
      section: "resource",
      capacity_label: cap && cap[:label],
      capacity_pct: cap && cap[:pct],
      chart_type: chart_type,
      # Gauges show the raw count in the center by default; the panel's "show %"
      # toggle (off by default) flips them back to the "% of peak" reading.
      percent: panel["percent"] == true,
      # scope/name/view/filter_query → the maximize button reconstructs the
      # panel in the expand modal (the HEP3 chart endpoint re-aggregates).
      scope: panel["scope"].to_s,
      name: panel["name"].to_s,
      view: view,
      filter_query: panel["filter_query"].to_s,
      default_visible: true,
      panel_key: key
    }
  end

  # hep_window — [from_epoch, to_epoch] the chart aggregates over, from the
  # dashboard's range (relative) or the custom from/until span.
  def hep_window
    to = custom? ? parse_epoch(@until_) : nil
    to ||= Time.now.to_i
    from = custom? ? parse_epoch(@from) : nil
    from ||= to - (range_ms / 1000)

    [from, to]
  end

  # hep_bucket_seconds — ~60 buckets across the range (min 30s), so the
  # sparkline honours the picker without over-fetching.
  def hep_bucket_seconds
    [(range_ms / 1000) / 60, 30].max
  end

  # hep_points — densify count_series ([[bucket_epoch, count], …]) into a
  # gap-free [{ts:, value:, formatted:}] over [from, to) so the sparkline is
  # continuous (empty buckets = 0).
  def hep_points(series, from, to, bucket)
    counts = series.to_h
    points = []
    b = (from / bucket) * bucket

    while b < to
      c = counts[b].to_i
      points << {ts: Time.at(b).utc.iso8601, value: c, formatted: c.to_s}
      b += bucket
    end

    points
  end

  def parse_epoch(value)
    Time.zone.parse(value.to_s).to_i
  rescue ArgumentError, TypeError
    nil
  end

  def table_chart_for(panel, key)
    view = panel["view"].presence || "messages"
    source = DataTable::Registry.build(
      panel["source"], island: @island, params: {scope: panel["scope"], name: panel["name"]}
    )

    {
      kind: :table,
      label: panel["label"].to_s,
      color: panel["color"].to_s,
      source: panel["source"].to_s,
      scope: panel["scope"].to_s,
      name: panel["name"].to_s,
      view: view,
      # Column metadata for the toolbar (picker + filter field list),
      # rendered server-side from the source — no rows here (the client
      # fetches those). Empty when the source no longer resolves.
      fields: source ? source.fields(view: view) : [],
      default_fields: source ? source.default_fields(view: view) : [],
      # Optional config-time pre-filter (DataTable DSL). The table opens
      # already filtered; the toolbar query is seeded from it.
      filter_query: panel["filter_query"].to_s,
      # row_action — the source's per-row drill-down (hep3 → call-flow;
      # nil for logs). Rendered as a leading icon by the DataTable.
      row_action: (source.respond_to?(:row_action) ? source.row_action : nil),
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
