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
    island = current_island
    return head(:not_found) unless island

    source = DataTable::Registry.build(
      params[:source],
      island: island,
      params: {scope: params[:scope], name: params[:name]}
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

    render json: {
      rows: source.rows(
        view: view,
        filter_query: filter_query,
        limit: limit_param,
        before_id: params[:before_id].presence&.to_i,
        since_id: params[:since_id].presence&.to_i,
        ts_from: window[:from],
        ts_to: window[:to]
      ),
      fields: source.fields(view: view),
      default_fields: source.default_fields(view: view)
    }
  end

  private

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
