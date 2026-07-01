# frozen_string_literal: true

# MetricsController — time-series charts page. Backed by
# MetricsPageData which fans out to the controller's /metrics
# endpoint for each chart.
#
# All state in the URL: ?scope_kind=host|pod&scope_id=<id>&range=<id>
# — operators bookmark a specific chart view, browser back/forward
# work naturally, and refresh keeps the same scope+range.
class MetricsController < ApplicationController
  def index
    # Restore the operator's last dashboard view on a bare landing
    # (session-scoped, 1h TTL) so leaving and returning to /metrics
    # reopens where they were. Explicit ?pid / scope skip this; the
    # polling frame always carries params so it never redirects.
    if restore_last_view? && (last = last_metrics_view).present?
      redirect_to(metrics_path(pid: last)) and return
    end

    remember_metrics_view if params[:pid].present? && full_page_request?

    @data = voodu_client.nil? ? nil : build_metrics_data

    # Turbo-Frame request → polling tick. Render JUST the chart_grid
    # inside the matching frame tag; Turbo extracts it and swaps the
    # frame contents atomically. layout: false skips the Dashboard
    # chrome — sidebar/topbar/page_head don't need to re-render on
    # every 30s tick.
    if request.headers["Turbo-Frame"] == "metrics-charts"
      render Views::Metrics::Frame.new(data: @data), layout: false
    else
      render Views::Metrics::Index.new(**dashboard_context.merge(data: @data))
    end
  end

  # chart — backs the expand-to-modal flow on /metrics. Two formats:
  #
  #   turbo_stream (default, when triggered by maximize button or
  #   in-modal picker change): returns a stream that
  #     1. updates #chart-modal-title with the metric label
  #     2. replaces #chart-modal-body with a fresh ChartModalBody
  #     3. invokes the custom :chart_modal_open Turbo action so
  #        the shared modal becomes visible (idempotent if open)
  #   All in ONE request — no client-side state to coordinate.
  #
  #   html (cmd-click or direct URL access): redirects back to
  #   /metrics with the scope/range params preserved. Honest
  #   hyperlink semantics — the URL leads somewhere viewable
  #   instead of returning a JSON-like fragment to bare browsers.
  #
  # Params (all required after the scope_kind/scope_id/range trio):
  #   metric  — series key, e.g. "cpu_percent"
  #   scale   — :percent | :bytes_to_mb | :bytes_to_gb | :bytes_auto | :count | :ms
  #   label   — display name ("CPU")
  #   color   — CSS var ("var(--voodu-accent)")
  #   unit    — "%" | "MB" | "GB" | "ms" | "" (auto-bytes resolves at fetch)
  #
  # Modal-scope isolation: this endpoint reads `range` from the
  # query string of THIS request — not the parent /metrics page —
  # so the picker inside the modal is local to the modal. Parent
  # page's range stays untouched.
  def chart
    respond_to do |format|
      format.html { redirect_to metrics_path(request.query_parameters.except(:metric, :scale, :label, :color, :unit)) }
      format.turbo_stream do
        if voodu_client.nil?
          head :not_found
          next
        end

        data = MetricsPageData.new(
          voodu_client,
          current_island,
          scope_kind: params[:scope_kind],
          scope_id: params[:scope_id],
          range: params[:range],
          interval: params[:interval],
          **custom_window
        )

        chart =
          if params[:source].to_s == "hep3"
            hep3_expand_chart
          else
            data.single_chart(
              metric: params[:metric].to_s,
              scale: params[:scale].presence&.to_sym,
              label: params[:label].to_s,
              color: params[:color].to_s,
              unit: params[:unit].to_s,
              chart_type: params[:chart_type].presence || :area
            )
          end

        if chart.nil?
          head :not_found
          next
        end

        body = Views::Metrics::ChartModalBody.new(
          chart: chart,
          range: params[:range].presence || "1h",
          range_ms: data.range_ms,
          query: request.query_parameters,
          # `data.all_pods` is the cached compact list (same one the
          # parent page's PodPicker uses). Always populate it — even
          # on host-scope modals, the in-modal picker needs the pod
          # list so the operator can drill from host into a pod
          # without closing the modal first.
          pods: data.all_pods,
          current_island: current_island,
          # Available metrics for the in-modal MetricPicker. Grouped
          # RESOURCE / HTTP. Pod-scope + ingress-eligible exposes
          # the full set (8 metrics); host gives 3; non-ingress pods
          # give 4. Computed server-side so the picker doesn't have
          # to know the rules.
          metric_sections: data.available_metric_specs
        )

        # Three-action stream covers the entire modal lifecycle in
        # one response:
        #   - title update so the header bar shows the right label
        #   - body replace so chart + picker + range pills are the
        #     fresh ones for the new (metric, scope, range)
        #   - chart_modal_open is idempotent — opens if closed,
        #     no-ops if already open (re-fetching the SAME modal
        #     after a pod/range switch just swaps content)
        render turbo_stream: [
          turbo_stream.update("chart-modal-title", chart[:label].to_s),
          turbo_stream.replace("chart-modal-body", body),
          turbo_stream.action(:chart_modal_open, "chart-modal")
        ]
      end
    end
  end

  # display_settings — lightweight endpoint for the "Display settings"
  # drawer. Renders the metric-toggle UI (no chart data needed — just
  # the spec metadata: label, color, metric key). The JS controller
  # reads sessionStorage on connect to restore the operator's saved
  # hidden-metrics set.
  #
  # Params:
  #   kind       — "deployment" | "statefulset" | "host" | "pod"
  #   scope_kind — "host" | "pod"
  #
  # Rendered WITHOUT layout (layout: false) because it lives inside
  # the Drawer panel, which provides its own chrome. The Drawer's
  # fetch() call injects the response HTML into its panel body and
  # Stimulus auto-connects the sub-controller.
  def display_settings
    # Dashboard mode — list the ACTIVE dashboard's panels (each a single
    # toggle card keyed by its panel_key) so the operator hides/reorders
    # exactly the charts on this dashboard. Falls through to the scope
    # path (host/pod fixed metric set) when no dashboard is given.
    if params[:pid].present? &&
        (dash = current_island.metric_dashboards.find_by(uuid: params[:pid]))
      render Views::Metrics::DisplaySettings.new(
        kind: "dashboard:#{dash.id}",
        items: dashboard_display_items(dash)
      ), layout: false
      return
    end

    kind = params[:kind].to_s.presence || "host"
    scope_kind = (params[:scope_kind].to_s == "pod") ? "pod" : "host"

    items = MetricsPageData.display_settings_items_for(scope_kind, kind)

    render Views::Metrics::DisplaySettings.new(
      kind: kind,
      items: items
    ), layout: false
  end

  private

  # hep3_expand_chart — rebuild a HEP3 count chart for the expand modal from
  # the maximize URL's params (a synthetic one-panel dashboard → the same
  # hep_chart_for the grid uses), so fullscreen re-aggregates the same slice.
  def hep3_expand_chart
    panel = {
      "scope_kind" => "table", "chart_type" => params[:chart_type].presence || "area",
      "source" => "hep3", "scope" => params[:scope].to_s, "name" => params[:name].to_s,
      "view" => params[:view].presence || "messages", "filter_query" => params[:filter_query].to_s,
      "label" => params[:label].to_s, "color" => params[:color].to_s,
      "percent" => params[:percent].to_s == "true"
    }
    dashboard = current_island.metric_dashboards.new(panels: [panel])

    MetricDashboardData.new(voodu_client, current_island, dashboard,
      range: params[:range], interval: params[:interval], **custom_window).charts.first
  end

  # build_metrics_data — picks the /metrics data object:
  #
  #   1. ?pid=a,b,c (≥2) → MultiDashboardData (stacked, selection order).
  #   2. ?pid=<uuid>     → MetricDashboardData (single dashboard).
  #   3. ?scope_kind/scope_id → MetricsPageData (pod/host scope drill-
  #      down, e.g. a pod's "View metrics" button).
  #   4. no pid + no scope → the pinned dashboard, if any.
  #   5. nothing pinned (or zero dashboards) → nil → the page renders the
  #      empty state until the operator picks a dashboard.
  def build_metrics_data
    dashboards = explicit_dashboards

    if dashboards.size > 1
      return MultiDashboardData.new(voodu_client, current_island, dashboards,
        range: params[:range], interval: params[:interval], **custom_window)
    elsif dashboards.size == 1
      return MetricDashboardData.new(voodu_client, current_island, dashboards.first,
        range: params[:range], interval: params[:interval], **custom_window)
    end

    if params[:scope_kind].present? || params[:scope_id].present?
      return MetricsPageData.new(voodu_client, current_island,
        scope_kind: params[:scope_kind], scope_id: params[:scope_id],
        range: params[:range], interval: params[:interval], **custom_window)
    end

    pinned = current_island.metric_dashboards.pinned.first
    return nil if pinned.nil?

    MetricDashboardData.new(
      voodu_client,
      current_island,
      pinned,
      range: params[:range],
      interval: params[:interval],
      **custom_window
    )
  end

  # custom_window — {from:, until_:} Time pair for `range=custom` mode, else
  # {from: nil, until_: nil}. Only populated when the range pill is "custom"
  # AND both bounds parse AND until_ > from; a malformed/half/inverted pair
  # collapses to nil so the data objects fall back to the relative `range`.
  # Mirrors Logs Analytics: the absolute window is the focus, `range` is just
  # a shortcut that seeds it.
  def custom_window
    @custom_window ||=
      if params[:range].to_s == "custom"
        f = parse_window_param(params[:from])
        u = parse_window_param(params[:until])

        (f && u && u > f) ? {from: f, until_: u} : {from: nil, until_: nil}
      else
        {from: nil, until_: nil}
      end
  end

  def parse_window_param(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # explicit_dashboards — ordered, deduped dashboards from ?pid=a,b,c
  # (selection order preserved). Unknown/deleted uuids are dropped.
  def explicit_dashboards
    ids = params[:pid].to_s.split(",").map(&:strip).reject(&:blank?).uniq
    return [] if ids.empty?

    ids.filter_map { |id| current_island.metric_dashboards.find_by(uuid: id) }
  end

  # ── Last-view memory ──────────────────────────────────────────────
  # Remember the operator's last ?pid selection per session + island so
  # a bare /metrics reopens it. Cached (not stored in the URL) with a 1h
  # TTL — leave for a while and the landing falls back to pinned/empty.

  def full_page_request?
    request.headers["Turbo-Frame"].blank?
  end

  def restore_last_view?
    full_page_request? &&
      params[:pid].blank? && params[:scope_kind].blank? && params[:scope_id].blank?
  end

  # last_metrics_view — the cached ?pid, filtered to dashboards that
  # still exist (a since-deleted one shouldn't strand the landing).
  def last_metrics_view
    key = metrics_last_view_key
    return nil if key.nil?

    raw = Rails.cache.read(key)
    return nil if raw.blank?

    uuids = raw.to_s.split(",").map(&:strip).select { |u| current_island.metric_dashboards.exists?(uuid: u) }
    uuids.join(",").presence
  end

  def remember_metrics_view
    key = metrics_last_view_key
    return if key.nil?

    Rails.cache.write(key, params[:pid].to_s, expires_in: 1.hour)
  end

  # Stable per-session token (kept in the session cookie) + island id.
  # No `current_user` here — the WebUI is tenant-by-URL — so the session
  # IS the "user" scope.
  def metrics_last_view_key
    return nil if current_island.nil?

    sid = (session[:metrics_sid] ||= SecureRandom.hex(8))

    "metrics:last_view:#{sid}:#{current_island.id}"
  end

  # dashboard_display_items — one Settings/Order card per dashboard
  # panel, keyed by the SAME panel_key the chart grid emits
  # (MetricDashboard.panel_card_key) so hide + reorder line up. All
  # single cards (no Latency/Errors grouping) since the operator
  # already curated the exact set.
  def dashboard_display_items(dash)
    Array(dash.panels).each_with_index.map do |panel, i|
      metric = panel["metric"].to_s

      {
        kind: :single,
        metric: MetricDashboard.panel_card_key(i),
        label: panel["label"].to_s,
        color: panel["color"].to_s,
        unit: panel["unit"].to_s,
        section: MetricsPageData::INGRESS_METRICS.include?(metric) ? "http" : "resource",
        default_visible: true
      }
    end
  end
end
