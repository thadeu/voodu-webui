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
    data = current_island && LogSearchData.new(island: current_island, params: search_params)
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
          pods: data ? pods_for_picker : [],
          data: data
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
      island: current_island,
      pod: params[:pod].to_s,
      ts: params[:ts].to_s,
      all_pods: params[:all_pods] == "1",
      expand: params[:expand].to_i
    )

    # `fmt` present → export the EXACT batch on screen (the same window /
    # expand the modal shows) as a download. Otherwise render the modal.
    if EXPORT_TYPES.key?(params[:fmt].to_s)
      fmt = params[:fmt].to_s
      send_data(
        format_rows(data.rows, fmt),
        filename: "surrounding-#{current_island.key}-#{Time.current.utc.strftime("%Y%m%d-%H%M%S")}.#{EXPORT_TYPES[fmt][:ext]}",
        type: EXPORT_TYPES[fmt][:mime],
        disposition: "attachment"
      )

      return
    end

    render Views::LogsAnalytics::Surrounding.new(data: data), layout: false
  end

  # export — stream the CURRENT query's result set as a download (or read
  # by the Copy actions via fetch). Synchronous: the query is bounded, so
  # no async job / status surface — unlike the live-tail export drawer
  # which handles unbounded dumps. Reuses LogSearchData to resolve the
  # window/filters, then LogTail::Reader + LineFormatter to serialise.
  EXPORT_LINE_CAP = 50_000

  EXPORT_TYPES = {
    "ndjson" => {ext: "ndjson", mime: "application/x-ndjson"},
    "csv" => {ext: "csv", mime: "text/csv; charset=utf-8"},
    "txt" => {ext: "txt", mime: "text/plain; charset=utf-8"},
    "json" => {ext: "json", mime: "application/json; charset=utf-8"}
  }.freeze

  def export
    return head(:not_found) if current_island.nil?

    data = LogSearchData.new(island: current_island, params: search_params)
    fmt = EXPORT_TYPES.key?(params[:fmt].to_s) ? params[:fmt].to_s : "ndjson"

    body = (fmt == "json") ? export_json(data) : export_lines(data, fmt)

    send_data(
      body,
      filename: "logs-#{current_island.key}-#{Time.current.utc.strftime("%Y%m%d-%H%M%S")}.#{EXPORT_TYPES[fmt][:ext]}",
      type: EXPORT_TYPES[fmt][:mime],
      disposition: "attachment"
    )
  end

  private

  # export_lines — header (if any) + one LineFormatter line per matched
  # record, in chronological (Reader) order. Bounded by EXPORT_LINE_CAP.
  def export_lines(data, fmt)
    body = +""
    head = LogTail::LineFormatter.header(fmt)
    body << head if head
    each_export_record(data) { |hash| body << LogTail::LineFormatter.line(hash, fmt) }
    body
  end

  # format_rows — serialise an already-materialised array of rows (the
  # surrounding window) into the requested format. Same formatter as the
  # streaming export, so output matches.
  def format_rows(rows, fmt)
    return JSON.pretty_generate(rows.map { |h| LogTail::LineFormatter.row_hash(h) }) if fmt == "json"

    body = +""
    head = LogTail::LineFormatter.header(fmt)
    body << head if head
    rows.each { |h| body << LogTail::LineFormatter.line(h, fmt) }
    body
  end

  # export_json — a pretty-printed JSON array of the 5-field shape
  # (ts/pod/stream/level/msg). Built in the controller since JSON output
  # isn't line-oriented. Pretty (indented) because this is the Copy-as-
  # JSON target — meant to be read/pasted, not the compact line-per-record
  # ndjson.
  def export_json(data)
    rows = []
    each_export_record(data) { |hash| rows << LogTail::LineFormatter.row_hash(hash) }
    JSON.pretty_generate(rows)
  end

  def each_export_record(data, &block)
    reader = LogTail::Reader.each_line(
      island_id: data.island.id,
      pods: data.pods.presence,
      from: data.from,
      until_: data.until_,
      content_search: data.search.presence,
      regex: data.regex?,
      limit: EXPORT_LINE_CAP
    )

    # No `| limit N` → stream straight through (chronological, Reader order).
    return reader.each { |_pod, hash| block.call(hash) } unless data.query_limit

    # `limit N` → export the SAME newest-N the screen shows. Reader yields
    # per-pod chronological, so buffer, sort, keep the newest N, then emit in
    # chronological order (matching the unlimited export's ordering). Bounded
    # by EXPORT_LINE_CAP, so the buffer can't run away.
    buffer = []
    reader.each { |_pod, hash| buffer << hash }
    buffer.sort_by! { |hash| (hash[:ts] || hash["ts"]).to_s }
    buffer.last(data.query_limit).each(&block)
  end

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
