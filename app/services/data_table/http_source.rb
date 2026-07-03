# frozen_string_literal: true

module DataTable
  # DataTable::HttpSource — a DataTable source backed by an operator-configured
  # EXTERNAL API. Instead of reading a local warehouse, it fires one outbound
  # request (HttpFetch) and maps the JSON response into rows (JsonMap). The
  # request config (url / method / headers / body / mapping / interval) lives
  # in the panel JSON, NOT in the client query string — so auth headers stay
  # server-side. The endpoint re-resolves the panel by (dashboard uuid,
  # panel_key); the server-render envelope hands the panel directly.
  #
  # POC contract: STATELESS — the response IS the render. No warehouse, no
  # paging cursors, no live-append; `rows` returns the whole mapped response
  # each call and the client's load()/refresh replaces wholesale (so a
  # per-row "id" = array index is stable enough). The page's window +
  # interval + scope + label ride the OUTBOUND request as query params, so the
  # external API decides what to return.
  class HttpSource
    DEFAULT_VIEW = "response"
    VIEWS = [{key: "response", label: "Response", realtime: "refresh"}].freeze

    LABEL = "HTTP — external API"
    SHORT_LABEL = "HTTP"

    # Raised by `rows` when the outbound request fails; the controller turns it
    # into a 502 carrying the message so the operator sees WHY (timeout, HTTP
    # 500, bad JSON) instead of a silent empty table.
    FetchError = Class.new(StandardError)

    def self.label = LABEL

    def self.short_label = SHORT_LABEL

    # available_for? — false: HTTP is its OWN panel-type card in the builder
    # (URL + mapping), not one of the generic Table sources (logs/hep3) the
    # Registry.available dropdown lists. It stays registered so Registry.build
    # can still resolve it for the rows endpoint + the render envelope.
    def self.available_for?(_island) = false

    def self.view_options
      VIEWS.map { |v| {key: v[:key], label: v[:label], fields: []} }
    end

    # from_params — two build paths resolve to the same panel config:
    #   • server render (envelope) hands the panel directly (`params[:panel]`)
    #   • the rows endpoint hands (dashboard uuid, panel_key) → we load it
    # nil (→ 404) when neither yields a panel carrying a url.
    def self.from_params(island:, params:)
      panel = params[:panel] || locate_panel(island, params[:dashboard], params[:panel_key])
      return nil unless panel.is_a?(Hash) && panel["url"].to_s.present?

      new(island: island, panel: panel)
    end

    def self.locate_panel(island, dashboard_uuid, panel_key)
      return nil if dashboard_uuid.blank? || panel_key.blank?

      dash = island.metric_dashboards.find_by(uuid: dashboard_uuid.to_s)
      return nil unless dash

      Array(dash.panels)[panel_key.to_s.delete_prefix("k").to_i]
    end

    def initialize(island:, panel:)
      @island = island
      @panel = panel
    end

    def views = VIEWS

    def default_view = DEFAULT_VIEW

    # row_action — no per-row drill-down for an external source.
    def row_action = nil

    # live_stream — nil: no realtime channel. The table refreshes on demand
    # (each Refresh re-fires the request).
    def live_stream = nil

    # fields / default_fields — the columns come from the operator's mapping,
    # not a fixed schema (schema-less, like every DataTable source). All mapped
    # columns are shown by default.
    def fields(view: DEFAULT_VIEW)
      columns.filter_map { |c| c["field"].to_s.presence }
    end

    def default_fields(view: DEFAULT_VIEW) = fields(view: view)

    # rows — fire the outbound request, map the JSON into rows. Ignores the
    # paging/live cursors (before_id/since_id): the response is the whole set,
    # replaced on every load. Honours `limit` as a safety cap.
    def rows(view: DEFAULT_VIEW, filter_query: nil, limit: 100, before_id: nil, since_id: nil, ts_from: nil, ts_to: nil)
      result = fetch(ts_from: ts_from, ts_to: ts_to)
      raise FetchError, result.error unless result.ok?

      map_rows(result.json).first(limit)
    end

    # Preview — the Test-button payload: the raw response (so the operator sees
    # the shape they're mapping against) PLUS the mapped output (so they confirm
    # the paths resolve). `ok?` false → `error` carries why.
    Preview = Struct.new(:ok, :error, :raw, :rows, :series, :fields) do
      def ok? = ok
    end

    # preview — fire ONE request and return both sides of the Test loop. `chart`
    # picks whether to map into series (ts/value points) or rows (columns).
    def preview(chart: false, ts_from: nil, ts_to: nil)
      result = fetch(ts_from: ts_from, ts_to: ts_to)
      return Preview.new(ok: false, error: result.error) unless result.ok?

      if chart
        Preview.new(ok: true, raw: result.json, series: map_series(result.json))
      else
        Preview.new(ok: true, raw: result.json, rows: map_rows(result.json), fields: fields)
      end
    end

    # series — the chart path: the response's OWN timeline. The mapping's `ts`
    # + `value` paths pull [{ts:, value:, formatted:}] straight out (no
    # bucketing/densifying — 1 returned point → 1 dot, 500 → 500), sorted by
    # ts. A fetch failure degrades to [] (an empty chart, not a broken page) —
    # the chart renders server-side, so it can't surface an error mid-render.
    def series(ts_from: nil, ts_to: nil)
      result = fetch(ts_from: ts_from, ts_to: ts_to)
      return [] unless result.ok?

      map_series(result.json)
    end

    private

    def mapping = @panel["mapping"].is_a?(Hash) ? @panel["mapping"] : {}

    def columns = Array(mapping["columns"])

    def fetch(ts_from:, ts_to:)
      DataTable::HttpFetch.call(
        url: @panel["url"],
        method: @panel["method"],
        headers: @panel["headers"],
        body: @panel["body"],
        query: outbound_query(ts_from, ts_to)
      )
    end

    # outbound_query — the webui context the external API needs to answer:
    # the resolved absolute window (from/until ISO), the concrete interval,
    # the scope, and the panel label. Absolute timestamps (not a relative
    # "1h") so there's no clock-skew ambiguity on the API's side.
    def outbound_query(ts_from, ts_to)
      {
        "from" => ts_from && Time.at(ts_from).utc.iso8601,
        "until" => ts_to && Time.at(ts_to).utc.iso8601,
        "interval" => resolved_interval(ts_from, ts_to),
        "scope" => @panel["scope"].to_s.presence,
        "label" => @panel["label"].to_s.presence
      }.compact
    end

    # resolved_interval — a CONCRETE value, never "auto": the webui knows the
    # window, the API doesn't. A configured non-auto interval passes through;
    # otherwise ~60 buckets across the window (min 30s).
    def resolved_interval(ts_from, ts_to)
      configured = @panel["interval"].to_s
      return configured if configured.present? && configured != "auto"
      return "60s" unless ts_from && ts_to

      span = (ts_to - ts_from).abs
      "#{[span / 60, 30].max.to_i}s"
    end

    def map_rows(json)
      cols = columns

      JsonMap.array_at(json, mapping["root"]).each_with_index.map do |item, i|
        row = {"id" => i}
        cols.each { |c| row[c["field"].to_s] = stringify(JsonMap.dig(item, c["path"])) }
        row
      end
    end

    def stringify(value)
      case value
      when nil then ""
      when Hash, Array then value.to_json
      else value.to_s
      end
    end

    def map_series(json)
      ts_path = mapping["ts"]
      value_path = mapping["value"]

      JsonMap.array_at(json, mapping["root"]).filter_map do |item|
        ts = normalize_ts(JsonMap.dig(item, ts_path))
        raw = JsonMap.dig(item, value_path)
        next if ts.nil? || raw.nil?

        value = raw.to_f
        {ts: ts, value: value, formatted: format_value(value)}
      end.sort_by { |p| p[:ts] }
    end

    # normalize_ts — coerce a mapped timestamp to the ISO8601 string the chart
    # expects. Accepts an ISO string or epoch seconds/millis; nil on anything
    # unparseable (the point is dropped rather than crash the render).
    def normalize_ts(raw)
      case raw
      when Numeric then Time.at((raw > 1e12) ? raw / 1000.0 : raw.to_f).utc.iso8601(3)
      when String then Time.zone.parse(raw)&.iso8601(3)
      end
    rescue ArgumentError, TypeError
      nil
    end

    def format_value(value)
      (value == value.to_i) ? value.to_i.to_s : value.round(2).to_s
    end
  end
end
