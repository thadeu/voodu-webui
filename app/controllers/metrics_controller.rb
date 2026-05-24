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

    render Views::Metrics::Index.new(**dashboard_context.merge(data: @data))
  end
end
