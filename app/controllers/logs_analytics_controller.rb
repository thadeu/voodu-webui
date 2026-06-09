# frozen_string_literal: true

# LogsAnalyticsController — historical log search (/logs/analytics).
# Reads the local NDJSON warehouse via LogSearchData; no controller
# round-trip, no live stream. The companion to LogsController's live
# tail: that one watches the newest lines forever, this one answers
# "show me what happened, filtered, and let me drill in / export".
#
# `index` is dual-mode (same shape as the Turbo-Frame branch in
# MetricsController / LogsController#show):
#   - Turbo-Frame request → render ONLY the results frame, so the filter
#     bar re-queries without reloading the page chrome.
#   - Full navigation → render the whole page with the query applied, so
#     /logs/analytics?range=1h&q=callid is bookmarkable + shareable.
class LogsAnalyticsController < ApplicationController
  def index
    data  = current_island && LogSearchData.new(island: current_island, params: search_params)
    frame = request.headers["Turbo-Frame"]

    if data && frame&.start_with?("la-page-")
      # "Load more" click — append the next page into its own frame.
      render Views::LogsAnalytics::MoreRows.new(data: data), layout: false
    elsif data && frame.present?
      # Filter-bar re-query — swap just the results table.
      render Views::LogsAnalytics::Results.new(data: data), layout: false
    else
      render Views::LogsAnalytics::Index.new(
        **dashboard_context.merge(
          updated_at: Time.current,
          pods:       data ? pods_for_picker : [],
          data:       data
        )
      )
    end
  end

  # surrounding — Surrounding Logs modal body: the lines immediately
  # before/after one anchor row in its log stream. Fetched + injected as
  # an overlay by the log-analytics controller, so it returns bare markup.
  def surrounding
    return head(:not_found) if current_island.nil?

    data = LogSurroundingData.new(
      island:   current_island,
      pod:      params[:pod].to_s,
      ts:       params[:ts].to_s,
      before:   (params[:before].presence || LogSurroundingData::DEFAULT_CONTEXT).to_i,
      after:    (params[:after].presence  || LogSurroundingData::DEFAULT_CONTEXT).to_i,
      all_pods: params[:all_pods] == "1"
    )

    render Views::LogsAnalytics::Surrounding.new(data: data), layout: false
  end

  private

  # search_params — the operator's filter choices. `pods` is an array so
  # the multi-pod case is one shape; the rest are scalars. `page` drives
  # Load more. Symbolised so LogSearchData's accessors read uniformly.
  def search_params
    params.permit(:range, :from, :until, :q, :regex, :page, pods: []).to_h.symbolize_keys
  end

  # pods_for_picker — compact pod list for the scope dropdown. Shares the
  # IslandPods cache cell with /logs + /metrics (no extra round-trip when
  # the operator bounces between surfaces).
  def pods_for_picker
    IslandPods.compact(voodu_client, current_island)
  end
end
