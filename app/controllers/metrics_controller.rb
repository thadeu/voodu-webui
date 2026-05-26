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
    if voodu_client.nil?
      @data = nil
    else
      @data = MetricsPageData.new(
        voodu_client,
        current_island,
        scope_kind: params[:scope_kind],
        scope_id:   params[:scope_id],
        range:      params[:range],
        interval:   params[:interval]
      )
    end

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
          scope_id:   params[:scope_id],
          range:      params[:range],
          interval:   params[:interval]
        )

        chart = data.single_chart(
          metric: params[:metric].to_s,
          scale:  params[:scale].presence&.to_sym,
          label:  params[:label].to_s,
          color:  params[:color].to_s,
          unit:   params[:unit].to_s
        )

        if chart.nil?
          head :not_found
          next
        end

        body = Views::Metrics::ChartModalBody.new(
          chart:           chart,
          range:           params[:range].presence || "1h",
          range_ms:        data.range_ms,
          query:           request.query_parameters,
          # `data.all_pods` is the cached compact list (same one the
          # parent page's PodPicker uses). Always populate it — even
          # on host-scope modals, the in-modal picker needs the pod
          # list so the operator can drill from host into a pod
          # without closing the modal first.
          pods:            data.all_pods,
          current_island:  current_island,
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
    kind       = params[:kind].to_s.presence || "host"
    scope_kind = params[:scope_kind].to_s == "pod" ? "pod" : "host"

    items = MetricsPageData.display_settings_items_for(scope_kind, kind)

    render Views::Metrics::DisplaySettings.new(
      kind:  kind,
      items: items
    ), layout: false
  end

end
