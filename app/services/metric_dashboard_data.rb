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

  # Distinct, high-contrast hues auto-assigned to the lines of a multi-series
  # (multi-pod) chart — series i gets colors[i]. Drawn from the chart palette;
  # red stays reserved for errors. Capped by MetricDashboard::MAX_SERIES (5).
  MULTI_SERIES_COLORS = %w[
    var(--voodu-purple) var(--voodu-blue) var(--voodu-teal)
    var(--voodu-amber) var(--voodu-pink)
  ].freeze

  # M2: a dashboard belongs to the ORG and each panel carries its own
  # server_id, so this takes the org (not a single client/server). Each panel
  # resolves its OWN server (scoped to the org — cross-org ids are dropped) and
  # gets a client + pod list memoised per server.
  def initialize(org, dashboard, range:, interval: nil, from: nil, until_: nil)
    @org = org
    @dashboard = dashboard
    @range = MetricsPageData::RANGES.key?(range) ? range : MetricsPageData::DEFAULT_RANGE
    @interval = MetricsPageData::INTERVALS.include?(interval) ? interval : MetricsPageData::DEFAULT_INTERVAL
    @from = from
    @until_ = until_
  end

  # servers_by_id — the org's servers keyed by id-as-string, for the per-panel
  # server_id lookup. The org scoping IS the isolation guard: a panel with an
  # server_id outside the org resolves to nil and is dropped.
  def servers_by_id
    @servers_by_id ||= (@org&.servers || []).index_by { |i| i.id.to_s }
  end

  # panel_server — the server a panel reads from. nil when the panel has no
  # server_id (http/external) or references a server outside the org.
  def panel_server(panel)
    servers_by_id[panel["server_id"].to_s]
  end

  # client_for / pods_for — memoised per server so N panels on the same server
  # share one PAT client + one compact pod list.
  def client_for(server)
    return nil if server.nil?

    (@clients ||= {})[server.id] ||= Voodu::Client.new(server)
  end

  def pods_for(server)
    return [] if server.nil?

    (@pods_cache ||= {})[server.id] ||= ServerPods.compact(client_for(server), server)
  end

  # any_server — a fallback server for panels with no server of their own
  # (http/external): the org's first. Its client is unused by HttpFetch (the
  # request is external), it just satisfies the DataTable::Registry signature.
  def any_server
    @any_server ||= @org&.servers&.min_by(&:name)
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
    return [] if @dashboard.nil? || @org.nil?

    panels.each_with_index.map { |panel, i| chart_for(panel, i) }.compact
  end

  # chart_at — the chart envelope for ONE panel by index. The maximize modal
  # needs just the one panel (a multi chart references its dashboard + index),
  # so this avoids rebuilding the whole grid. nil for an out-of-range index.
  def chart_at(index)
    return nil if @dashboard.nil? || @org.nil?

    panel = panels[index]
    panel && chart_for(panel, index)
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
  # custom window, used only to reuse its custom_window_ms math for range_ms
  # (date arithmetic — the server is irrelevant, so any_server suffices).
  def scope_page
    @scope_page ||= MetricsPageData.new(
      client_for(any_server), any_server, scope_kind: "host", scope_id: nil,
      range: @range, interval: @interval, from: @from, until_: @until_
    )
  end

  private

  def panels
    Array(@dashboard&.panels)
  end

  def warehouse?
    defined?(ServerState) && ServerState.warehouse?
  end

  # chart_for — resolve the panel's scope, then reuse
  # MetricsPageData#single_chart for the fetch + scale + capacity.
  # Merges scope_kind/scope_id back so the ChartCard maximize button
  # can build its /metrics/chart expand URL for the right series.
  def chart_for(panel, index)
    key = MetricDashboard.panel_card_key(index)
    http = panel["scope_kind"].to_s == "table" && panel["source"].to_s == "http"

    # server — the server this panel reads from, resolved WITHIN the org
    # (the isolation guard). http/external panels have no server, so they fall
    # back to any_server (unused by the external fetch). A server panel whose
    # server_id isn't in this org (deleted / cross-org forged) → a placeholder,
    # never a cross-org read.
    server = http ? any_server : panel_server(panel)
    return missing_card(panel, key) if server.nil? && !http

    return log_chart_for(panel, key, server) if panel["scope_kind"].to_s == "log"

    if panel["scope_kind"].to_s == "table"
      # A HEP3 group-by query (`… | count()/count(distinct X) by <field>`) renders
      # PER GROUP: Line/Area → one series per value; Table → grouped rows; Bar →
      # grouped bars; Number → the grand total. Detected from the query's pipeline.
      if panel["source"].to_s == "hep3"
        plan = DataTable::QueryPlan.compile(panel["filter_query"].to_s)

        return hep_grouped_chart_for(panel, plan, key, server, index) if plan.grouped?
      end

      # A "table" panel is DataTable-family: chart_type "table" → rows;
      # anything else (area/number/gauge) → a count/timeseries chart. The http
      # source maps the response's own points into the series; hep3 counts.
      return table_chart_for(panel, key, server) if panel["chart_type"].to_s == "table"
      return http_chart_for(panel, key, server) if http

      return hep_chart_for(panel, key, server)
    end

    # Multi-series (2+ pod/host members on shared axes) routes here regardless of
    # the anchor's scope_kind — a Host + pod chart is anchored on the host but is
    # still a multi chart.
    return multi_series_chart_for(panel, key, index) if multi_series?(panel)

    if panel["scope_kind"].to_s == "pod"
      scope_id = resolve_container(panel, server)
      return missing_card(panel, key) if scope_id.nil?

      scope_kind = "pod"
    else
      scope_kind = "host"
      scope_id = nil
    end

    ct = panel["chart_type"].presence || "area"

    # A warehouse metric draws a time-series, a gauge, or a Number tile (the
    # CURRENT value — the latest sample). Table (or any future render it can't
    # fill) has no chart, so the panel reads EMPTY — not a misleading area
    # fallback: the operator chose it knowingly.
    if ct != "number" && !METRIC_RENDERABLE.include?(ct)
      return zeroed_card(panel, key, scope_kind: scope_kind, scope_id: scope_id, server_id: server.id)
    end

    page = MetricsPageData.new(
      client_for(server), server,
      scope_kind: scope_kind, scope_id: scope_id,
      range: @range, interval: @interval, from: @from, until_: @until_
    )

    chart = page.single_chart(
      metric: panel["metric"].to_s,
      scale: panel["scale"].presence&.to_sym,
      label: panel["label"].to_s,
      color: panel["color"].to_s,
      unit: panel["unit"].to_s,
      chart_type: (ct == "number") ? :area : ct
    )
    return missing_card(panel, key) if chart.nil?

    # Number render → a big-number "stat" tile of the CURRENT value, with the
    # trend as a sparkline. Reuses the same :number envelope log/HEP3/HTTP tiles
    # use. The headline is the last point's formatted string (already unit/scale
    # formatted by single_chart); an empty window → "—". show_chart? keeps or
    # drops the sparkline (absent → true, so it shows by default).
    if ct == "number"
      return {
        kind: :number, label: panel["label"].to_s, color: panel["color"].to_s,
        value: chart[:current],
        formatted: chart[:points].last&.dig(:formatted) || "—",
        series: show_chart?(panel) ? chart[:points] : [],
        range: @range, range_ms: range_ms,
        default_visible: true, panel_key: key
      }
    end

    # scope_kind/scope_id → so the ChartCard maximize button can build
    # the right /metrics/chart expand URL. default_visible: true → the
    # operator explicitly chose every panel, so never let the
    # metrics-display "hide picker-only HTTP metrics on first run"
    # heuristic hide one (an HTTP metric carries default_visible: false
    # from its spec). panel_key → the unique data-metric-key the
    # Settings/Order drawer toggles + reorders this panel by.
    chart.merge(scope_kind: scope_kind, scope_id: scope_id, server_id: server.id,
      default_visible: true, panel_key: key)
  end

  # METRIC_RENDERABLE — the chart types a warehouse metric (host/pod) can draw:
  # the time-series shapes + gauges. Number/Table have no metric render (those
  # are log/DataTable renders); a metric panel carrying one draws empty (zeroed).
  METRIC_RENDERABLE = %w[area bars line gauge_radial gauge_linear].freeze

  # MULTI_SERIES_CHART_TYPES — the styles that draw one mark per pod on shared
  # axes. Line (raio) + Area (line + translucent fill). Bar/gauges stay single.
  MULTI_SERIES_CHART_TYPES = %w[line area].freeze

  # multi_series? — a pod panel that draws one series per pod (Line or Area),
  # 2+ pods. (One pod falls through to the normal single-series path.)
  def multi_series?(panel)
    MULTI_SERIES_CHART_TYPES.include?(panel["chart_type"].to_s) && Array(panel["pods"]).size >= 2
  end

  # multi_series_chart_for — build a {series: [...]} envelope: one warehouse
  # fetch per pod (each with its own org-scoped server + resolved container),
  # a palette color + the pod name as the label. Pods that don't resolve (gone /
  # cross-org / no live replica) are simply dropped from the series list.
  def multi_series_chart_for(panel, key, index)
    metric = panel["metric"].to_s
    scale = panel["scale"].presence&.to_sym

    series = Array(panel["pods"]).each_with_index.filter_map do |entry, i|
      srv = servers_by_id[entry["server_id"].to_s]
      next if srv.nil?

      # A member is the host (node metrics, no container) or a pod (resolve its
      # live container). Every series reads the SAME metric key — CPU shares it
      # across host + pods; a metric whose key differs by kind (Memory) reads the
      # anchor's key, so the mismatched side comes back empty (operator's choice).
      if entry["scope_kind"].to_s == "host"
        page = MetricsPageData.new(
          client_for(srv), srv, scope_kind: "host", scope_id: nil,
          range: @range, interval: @interval, from: @from, until_: @until_
        )
        label = series_label(srv, "host")
      else
        container = resolve_container(entry, srv)
        next if container.nil?

        page = MetricsPageData.new(
          client_for(srv), srv, scope_kind: "pod", scope_id: container,
          range: @range, interval: @interval, from: @from, until_: @until_
        )
        label = series_label(srv, entry["name"].to_s)
      end

      sp = page.series_points(metric: metric, scale: scale)

      {label: label, color: MULTI_SERIES_COLORS[i % MULTI_SERIES_COLORS.size],
       points: sp[:points], current: sp[:current]}
    end

    return missing_card(panel, key) if series.empty?

    {
      label: panel["label"].to_s,
      metric: metric,
      scale: scale,
      unit: panel["unit"].presence || series_unit(series),
      chart_type: panel["chart_type"].presence || "line",
      multi: true,
      series: series,
      default_visible: true,
      panel_key: key,
      # dashboard_uuid + panel_index let the maximize modal reference THIS panel
      # (a multi chart can't be rebuilt from flat metric/scope params like a
      # single one — the endpoint reloads the dashboard + rebuilds its series).
      dashboard_uuid: @dashboard&.uuid,
      panel_index: index,
      # scope metadata (from the panel's primary pod) so the card still has a
      # server to anchor to.
      scope_kind: "pod", scope_id: nil, server_id: panel["server_id"].to_s
    }
  end

  # series_label — a multi-series member's legend label, ALWAYS "<server> · <base>"
  # so the server owning a "host" / pod line is explicit even in a single-server
  # org (mirrors the builder dropdown's source_text — an org can grow to N servers
  # and a bare name is ambiguous across them).
  def series_label(srv, base)
    "#{srv.name} · #{base}"
  end

  # series_unit — best-effort unit for the y-axis when the panel didn't store
  # one (e.g. bytes_auto): the trailing token of the first formatted value.
  def series_unit(series)
    fmt = series.filter_map { |s| s[:points].last }.first&.dig(:formatted).to_s

    fmt.include?(" ") ? fmt.split(" ").last : ""
  end

  # log_chart_for — a log-query panel: read the filter's pre-aggregated count
  # series (via LogMetricData) and reduce it per the query's `| agg` suffix. The
  # SAME series renders two ways, chosen by chart_type:
  #   number (default)   → a big-number tile + optional sparkline  [NumberCard]
  #   area | bars | line → the count-over-time as a chart           [ChartCard]
  # The chart's `current` reuses the reduced headline (data.value) so number and
  # chart of the same filter always agree. No new data source, no counter change
  # — the warehouse `log_count` series (fed for every scope_kind="log" panel) is
  # read either way.
  #
  # default_visible: true — the operator explicitly chose this panel, so the
  # metrics-display "hide picker-only on first run" heuristic must never hide
  # it. panel_key → the data-metric-key the Settings/Order drawer toggles by.
  def log_chart_for(panel, key, server)
    data = LogMetricData.new(
      server,
      query: panel["query"].to_s,
      range: @range,
      interval: @interval,
      scope: panel["scope"].to_s,
      name: panel["name"].to_s,
      from: @from,
      until_: @until_
    )

    chart_type = panel["chart_type"].presence || "number"

    # Chart render — the count series as a time-series. scope/name/query ride
    # along so the maximize modal can rebuild the panel (see log_expand_url).
    if %w[area bars line].include?(chart_type)
      return {
        label: panel["label"].to_s,
        color: panel["color"].to_s,
        unit: "",
        points: data.series,
        current: data.value,
        metric: key,
        source: "log",
        section: "resource",
        chart_type: chart_type,
        scope: panel["scope"].to_s,
        name: panel["name"].to_s,
        query: panel["query"].to_s,
        server_id: server&.id,
        default_visible: true,
        panel_key: key
      }
    end

    # A gauge (or any non-number, non-timeseries render) has no log-count chart —
    # the count is unbounded, so a gauge can't fill. It reads empty (zeroed).
    unless chart_type == "number"
      return zeroed_card(panel, key, source: "log", scope: panel["scope"].to_s,
        name: panel["name"].to_s, query: panel["query"].to_s, server_id: server&.id)
    end

    # Number tile (default) — the operator's `show_chart` toggle keeps or drops
    # the sparkline; an empty series makes the NumberCard render the number
    # alone. Absent key → true, so legacy panels keep their chart.
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
  def hep_chart_for(panel, key, server)
    source = DataTable::Registry.build(
      panel["source"], server: server, params: {scope: panel["scope"], name: panel["name"]}
    )
    chart_type = panel["chart_type"].presence || "area"
    view = panel["view"].presence || "messages"
    from, to = hep_window
    bucket = hep_bucket_seconds

    # Extract just the WHERE part of the query (a bare filter, or the filter stage
    # of a pipeline) so `@x | count()` still filters even without a `by`.
    filter_only = DataTable::QueryPlan.compile(panel["filter_query"].to_s).filter
    series = source ? source.count_series(view: view, filter_query: filter_only, ts_from: from, ts_to: to, bucket: bucket) : []
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
      # server_id → the maximize button rebuilds the expand modal against the
      # SAME server this panel reads from (not the URL's server).
      server_id: server&.id,
      default_visible: true,
      panel_key: key
    }
  end

  # hep_grouped_chart_for — a HEP3 group-by query (`… | count()/count(distinct X)
  # by <field>`). One aggregation, rendered by chart_type:
  #   number       → the grand total (all groups summed)
  #   table / bars → a SNAPSHOT: one row/bar per group value, sorted + capped
  #   line / area  → OVER TIME: one series per group (reuses the multi-series card)
  # `plan` is the parsed DataTable::QueryPlan::Plan; `index` lets a Line/Area
  # maximize reference this panel (multi charts rebuild from the dashboard).
  def hep_grouped_chart_for(panel, plan, key, server, index)
    source = DataTable::Registry.build(
      panel["source"], server: server, params: {scope: panel["scope"], name: panel["name"]}
    )
    return missing_card(panel, key) if source.nil?

    chart_type = panel["chart_type"].presence || "line"
    # The view (messages/calls/errors) sets the base semantics: on Calls, count()
    # counts distinct CALLS; on Errors, only 4xx/5xx rows. count(distinct X) in
    # the query overrides the metric regardless of view.
    view = panel["view"].presence || "messages"
    from, to = hep_window

    if chart_type == "number"
      total = source.grouped_snapshot(plan, ts_from: from, ts_to: to, view: view).sum { |g| g[:value] }

      return {
        kind: :number, label: panel["label"].to_s, color: panel["color"].to_s,
        formatted: total.to_s, value: total, series: [],
        range: @range, range_ms: range_ms, truncated: false, clamped: false, meta: nil,
        default_visible: true, panel_key: key
      }
    end

    # Snapshot renders (Table / Bar): one aggregated value per group.
    if chart_type == "table" || chart_type == "bars"
      groups = source.grouped_snapshot(plan, ts_from: from, ts_to: to, view: view)

      return {
        kind: (chart_type == "table") ? :group_table : :group_bar,
        label: panel["label"].to_s, color: panel["color"].to_s,
        field: plan.group_by.to_s, unit: "", groups: groups,
        default_visible: true, panel_key: key
      }
    end

    # Time-series renders (Line / Area): one series per group → the multi card.
    bucket = hep_bucket_seconds
    series_map = source.grouped_series(plan, ts_from: from, ts_to: to, bucket: bucket, view: view)
    series = series_map.each_with_index.map do |(label, pts), i|
      {label: label, color: MULTI_SERIES_COLORS[i % MULTI_SERIES_COLORS.size],
       points: hep_points(pts, from, to, bucket)}
    end

    # No groups matched in this window → an EMPTY chart (a flat-zero series keeps
    # the axes + label), NOT a "no running replica" placeholder: the reader IS
    # up, there's just nothing to group yet (mirrors the metric heartbeat-zero).
    if series.empty?
      series = [{label: plan.group_by.to_s, color: panel["color"].to_s, points: hep_points([], from, to, bucket)}]
    end

    {
      label: panel["label"].to_s, unit: "", chart_type: chart_type,
      multi: true, series: series,
      default_visible: true, panel_key: key,
      dashboard_uuid: @dashboard&.uuid, panel_index: index,
      scope_kind: "pod", scope_id: nil, server_id: server&.id
    }
  end

  # http_chart_for — an external-API source rendered as a chart. Unlike hep3
  # (which COUNTS warehouse rows into buckets), the response carries its OWN
  # timeline: the mapping's ts + value paths pull [{ts, value}] straight out,
  # so 1 returned point → 1 dot, 500 → a full timeline. The request fires HERE,
  # at render (the chart is server-side SVG); a fetch failure → an empty chart,
  # never a broken page. The headline is the latest point (a live reading),
  # not a sum — summing arbitrary external values (CPU %, temperatures) is
  # meaningless. Gauges read avg-vs-peak of the returned values.
  def http_chart_for(panel, key, server)
    source = DataTable::Registry.build(panel["source"], server: server, params: {panel: panel})
    chart_type = panel["chart_type"].presence || "area"
    from, to = hep_window

    points = source ? source.series(ts_from: from, ts_to: to) : []
    values = points.map { |p| p[:value] }
    latest = values.last.to_f
    formatted = format_http_value(latest)

    if chart_type == "number"
      return {
        kind: :number, label: panel["label"].to_s, color: panel["color"].to_s,
        formatted: formatted, value: latest, series: points,
        range: @range, range_ms: range_ms, truncated: false, clamped: false, meta: nil,
        default_visible: true, panel_key: key
      }
    end

    gauge = %w[gauge_radial gauge_linear].include?(chart_type)
    peak = values.max.to_f
    avg = points.empty? ? 0.0 : (values.sum.to_f / points.size)
    cap = if gauge
      {label: nil, pct: (peak.positive? ? ((avg / peak) * 100).round : 0)}
    end

    {
      label: panel["label"].to_s, color: panel["color"].to_s, unit: "",
      points: points, current: latest, metric: key,
      source: "http", section: "resource",
      capacity_label: cap && cap[:label], capacity_pct: cap && cap[:pct],
      chart_type: chart_type, percent: panel["percent"] == true,
      default_visible: true, panel_key: key
    }
  end

  def format_http_value(value)
    (value == value.to_i) ? value.to_i.to_s : value.round(2).to_s
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

  # hep_bucket_seconds — the bucket width for a HEP3 count/group chart. Honors
  # the operator's INTERVAL when set (15m → 900s buckets), matching the warehouse
  # charts; "auto" derives ~60 buckets across the range. Floored at 30s AND at
  # range/600 so a fine interval over a long range can't fan out into thousands
  # of raw-SQL buckets.
  def hep_bucket_seconds
    span = [range_ms / 1000, 60].max
    bucket = interval_seconds(@interval) || (span / 60)

    [bucket, span / 600, 30].max
  end

  # interval_seconds — an explicit interval ("15m"/"1h"/"10s") → seconds, or nil
  # for "auto"/unrecognised (→ the ~60-bucket auto derivation).
  def interval_seconds(iv)
    m = iv.to_s.match(/\A(\d+)(s|m|h)\z/) or return nil

    m[1].to_i * {"s" => 1, "m" => 60, "h" => 3600}.fetch(m[2])
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

  def table_chart_for(panel, key, server)
    view = panel["view"].presence || ((panel["source"].to_s == "http") ? "response" : "messages")
    # Pass the panel itself so an http source resolves its request config from
    # it directly (no dashboard/panel_key round-trip on the render path); hep3/
    # logs ignore it and read scope/name.
    source = DataTable::Registry.build(
      panel["source"], server: server,
      params: {scope: panel["scope"], name: panel["name"], panel: panel}
    )

    {
      kind: :table,
      label: panel["label"].to_s,
      color: panel["color"].to_s,
      source: panel["source"].to_s,
      # server_id → the DataTable rows fetch resolves THIS panel's server (M2),
      # so a table reading a reader on another org server queries the right
      # server. nil for http (external, no server).
      server_id: server&.id,
      scope: panel["scope"].to_s,
      name: panel["name"].to_s,
      view: view,
      # dashboard_uuid + panel_key let the client's rows fetch re-resolve an
      # http panel's config server-side (secrets never ride the query string).
      dashboard_uuid: @dashboard&.uuid,
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
  def resolve_container(panel, server)
    scope = panel["scope"].to_s
    name = panel["name"].to_s

    matches = pods_for(server).select do |p|
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

  # zeroed_card — a panel whose (measure, render) pairing has no chart today
  # draws EMPTY: an empty-points ChartCard, not an error (the replica IS running)
  # and not a misleading fallback. The operator knowingly chose a render the
  # measure can't fill (Memory as a Table, a log count as a gauge), and by product
  # decision that reads as zeroed. `zeroed: true` also suppresses the maximize
  # button (there's nothing to expand). `extra` carries the routing fields.
  def zeroed_card(panel, key, extra = {})
    {
      label: panel["label"].to_s,
      color: panel["color"].to_s,
      unit: panel["unit"].to_s,
      points: [],
      series: nil,
      current: nil,
      chart_type: panel["chart_type"].to_s,
      metric: panel["metric"].presence || key,
      zeroed: true,
      default_visible: true,
      panel_key: key
    }.merge(extra)
  end

  # field — read a key from a pod hash that may use string OR symbol
  # keys (ServerPods.compact returns string-keyed in warehouse mode,
  # and the live path mirrors it — but be defensive).
  def field(pod, key)
    return "" if pod.nil?

    (pod[key] || pod[key.to_sym]).to_s
  end
end
