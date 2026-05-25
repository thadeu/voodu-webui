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
        range:      params[:range]
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

  # chart — backs the expand-to-modal flow on /metrics. Renders a
  # SINGLE chart + range picker in a turbo-frame, no Dashboard
  # chrome. Operator clicks the maximize icon on a ChartCard →
  # Stimulus reveals the modal + sets the frame's src → this action
  # responds with the standalone chart body. Range pills inside the
  # modal swap the frame contents without closing the modal.
  #
  # Params (all required after the scope_kind/scope_id/range trio
  # the page-level controller already reads):
  #   metric    — series key, e.g. "cpu_percent"
  #   scale     — :percent | :bytes_to_mb | :bytes_to_gb | :bytes_auto | :count | :ms
  #   label     — display name ("CPU")
  #   color     — CSS var ("var(--voodu-accent)")
  #   unit      — "%" | "MB" | "GB" | "ms" | "" (auto-bytes resolves at fetch)
  #
  # Modal-scope isolation: this endpoint reads `range` from the
  # query string of THIS request — not the parent /metrics page —
  # so the range picker inside the modal is local to the modal.
  # The parent page's range stays untouched.
  def chart
    if voodu_client.nil?
      head :not_found
      return
    end

    data = MetricsPageData.new(
      voodu_client,
      current_island,
      scope_kind: params[:scope_kind],
      scope_id:   params[:scope_id],
      range:      params[:range]
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
      return
    end

    render Views::Metrics::ChartModalBody.new(
      chart:      chart,
      range:      params[:range].presence || "1h",
      range_ms:   data.range_ms,
      query:      request.query_parameters
    ), layout: false
  end
end
