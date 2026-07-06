# frozen_string_literal: true

# DatatableController — the rows feed for Table panels. Serves one page of
# a DataSource (DataTable::Registry) as JSON; the DataTable Stimulus
# controller pulls from here for the initial load, infinite scroll
# (before_id), filtering, and live-append (since_id).
#
# Schema-less: the response carries the rows plus the source's field list
# (all columns) and default_fields (initial visible set) so the client can
# build the column picker without a separate schema call.
class DatatableController < ApplicationController
  DEFAULT_LIMIT = 100
  MAX_LIMIT = 500

  def rows
    island = panel_island
    return head(:not_found) unless island

    source = DataTable::Registry.build(
      params[:source],
      island: island,
      # scope/name identify a warehouse source (hep3/logs); dashboard/panel_key
      # let an http source re-resolve its stored request config (url + mapping)
      # server-side — the client never carries the URL or auth headers.
      params: {scope: params[:scope], name: params[:name],
               dashboard: params[:dashboard], panel_key: params[:panel_key]}
    )

    return head(:not_found) unless source

    view = params[:view].presence || source.default_view
    filter_query = params[:filter_query].to_s

    # A filter that won't parse must NOT fall through to unfiltered rows (that
    # reads as "the filter is broken" — the operator sees rows they excluded).
    # Surface the parse message and hold the rows back.
    if source.respond_to?(:filter_error) && (err = source.filter_error(filter_query))
      return render json: {rows: [], error: err, fields: source.fields(view: view),
                           default_fields: source.default_fields(view: view)}, status: :unprocessable_entity
    end

    window = time_window

    rows = source.rows(
      view: view,
      filter_query: filter_query,
      limit: limit_param,
      before_id: params[:before_id].presence&.to_i,
      since_id: params[:since_id].presence&.to_i,
      ts_from: window[:from],
      ts_to: window[:to]
    )

    render json: {rows: rows, fields: source.fields(view: view), default_fields: source.default_fields(view: view)}
  rescue DataTable::HttpSource::FetchError => e
    # An external-API source failed — surface WHY (timeout / HTTP 5xx / bad
    # JSON) instead of a silent empty table. 502: the upstream, not us.
    render json: {rows: [], error: e.message, fields: [], default_fields: []}, status: :bad_gateway
  end

  # test — the builder's "Test request" button. Fires the operator's in-progress
  # http config server-side (same path as render — secrets/SSRF stay off the
  # client) and returns BOTH the raw response (so they see the shape they're
  # mapping against) and the mapped output (rows or series, so they confirm the
  # paths resolve). The config isn't saved yet — it rides the POST body.
  def test
    island = current_island
    return head(:not_found) unless island

    mapping = parse_mapping(params[:mapping])
    return render(json: {ok: false, error: "the mapping isn't valid JSON"}) if mapping.nil?

    panel = {
      "url" => params[:url].to_s, "method" => params[:method].to_s,
      "headers" => parse_headers(params[:headers]), "body" => params[:body],
      "interval" => params[:interval].to_s, "scope" => params[:scope].to_s,
      "label" => params[:label].to_s, "mapping" => mapping
    }

    source = DataTable::HttpSource.new(island: island, panel: panel)
    chart = params[:chart_type].to_s.present? && params[:chart_type].to_s != "table"
    window = time_window
    preview = source.preview(chart: chart, ts_from: window[:from], ts_to: window[:to])

    render json: {
      ok: preview.ok?, error: preview.error, raw: preview.raw,
      rows: preview.rows, series: preview.series, fields: preview.fields
    }
  end

  private

  # panel_island — the server a Table panel reads from. A cross-server dashboard
  # panel passes ?island_id=… (M2); resolve it WITHIN current_org (the isolation
  # guard) so a forged / cross-org / deleted id never reaches another org's
  # warehouse tenant — it falls back to the URL's server. No island_id → the
  # URL's server (single-server / http panels).
  def panel_island
    if params[:island_id].present? && current_org
      current_org.islands.find_by(id: params[:island_id]) || current_island
    else
      current_island
    end
  end

  # parse_mapping — the json-editor's text is posted verbatim; parse it here so
  # a syntax slip surfaces as a clear Test error, not a silent empty mapping.
  # nil signals invalid JSON; an already-parsed hash (JSON body) passes through.
  def parse_mapping(raw)
    return raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    return {} if raw.blank?

    JSON.parse(raw.to_s)
  rescue JSON::ParserError
    nil
  end

  # parse_headers — accept "Key: Value" lines (operator-friendly) or an object.
  def parse_headers(raw)
    return raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)

    raw.to_s.lines.filter_map do |line|
      key, value = line.split(":", 2)
      next if value.nil? || key.strip.empty?

      [key.strip, value.strip]
    end.to_h
  end

  def limit_param
    n = params[:limit].to_i
    n = DEFAULT_LIMIT if n <= 0

    [n, MAX_LIMIT].min
  end

  # time_window — the {from:, to:} epoch-second bounds the table honours, from
  # the page's range picker (so the table follows the same window as the
  # charts). Relative range (1h/24h/…) → lower bound now−range, upper OPEN so
  # live rows still flow. `custom` → the explicit from/until span (both bounds
  # → a frozen historical window). No range → no bound (show everything).
  def time_window
    range = params[:range].to_s

    return {from: nil, to: nil} if range.blank?
    return {from: epoch(params[:from]), to: epoch(params[:until])} if range == "custom"

    {from: Time.now.to_i - (MetricsPageData.range_to_ms(range) / 1000), to: nil}
  end

  def epoch(value)
    Time.zone.parse(value.to_s).to_i
  rescue ArgumentError, TypeError
    nil
  end
end
