# frozen_string_literal: true

module DataTable
  # DataTable::FswapiSource — FreeSWITCH (voodu-fswapi plugin) as a dashboard
  # source, one per server: the plugin runs once per server as the builtin
  # resource plugins/fswapi, so a panel's scope/name are always that.
  #
  # Two kinds of view, like the /fswapi page:
  #
  #   - LISTS (calls, channels, registrations, gateways) are current state,
  #     read live through the PAT proxy (FswapiPageData: 5s cache, the same
  #     filter + 100-row cap) and never stored. Stateless like HttpSource:
  #     every load replaces the rows, so the row id is just its position.
  #   - HISTORY (calls, channels, sessions/s, idle CPU) is the warehouse
  #     series the overview sync writes every 15s (`series`), for the chart
  #     shapes. Registrations and gateways have no history; sessions/s and
  #     idle CPU have no list.
  #
  # Each view says which shapes it can take (`shapes`); the model refuses a
  # panel asking for one it can't, and the builder only offers those.
  class FswapiSource
    CHART_SHAPES = %w[number area bars line gauge_radial gauge_linear].freeze

    VIEWS = [
      {key: "calls", label: "Calls", realtime: "refresh", table: true, metric: "fs_calls"},
      {key: "channels", label: "Channels", realtime: "refresh", table: true, metric: "fs_channels"},
      {key: "registrations", label: "Registrations", realtime: "refresh", table: true},
      {key: "gateways", label: "Gateways", realtime: "refresh", table: true},
      {key: "sessions_per_sec", label: "Sessions / s", metric: "fs_sessions_per_sec"},
      {key: "idle_cpu", label: "Idle CPU (%)", metric: "fs_idle_cpu", unit: "%"}
    ].freeze

    DEFAULT_VIEW = "calls"

    LABEL = "FreeSWITCH"
    SHORT_LABEL = "FreeSWITCH"

    # The builtin resource every panel of this source reads.
    SCOPE = "plugins"
    NAME = "fswapi"

    # Raised by `rows` when FreeSWITCH (or the plugin) could not answer; the
    # rows endpoint turns it into a 502 carrying the plugin's message.
    FetchError = Class.new(StandardError)

    def self.label = LABEL

    def self.short_label = SHORT_LABEL

    def self.available_for?(server) = server.plugin_installed?("fswapi")

    def self.view_options
      VIEWS.map { |v| {key: v[:key], label: v[:label], fields: fields_for(v[:key]), shapes: shapes_for(v[:key])} }
    end

    def self.view(key) = VIEWS.find { |v| v[:key] == key.to_s }

    # shapes_for — the chart types a view can render: Table needs a live list,
    # every other shape needs a history metric.
    def self.shapes_for(key)
      v = view(key)

      return [] unless v

      (v[:table] ? ["table"] : []) + (v[:metric] ? CHART_SHAPES : [])
    end

    def self.fields_for(key)
      return [] unless view(key)&.dig(:table)

      Fswapi::Format.columns(key).map { |c| c[:field] }
    end

    def self.from_params(server:, params:)
      return nil unless server

      new(server: server)
    end

    def initialize(server:)
      @server = server
    end

    def views = VIEWS

    def default_view = DEFAULT_VIEW

    # row_action — none in a dashboard table: the SIP-flow drill-down needs
    # the channel tree of the /fswapi page.
    def row_action = nil

    def live_stream = nil

    def fields(view: DEFAULT_VIEW) = self.class.fields_for(view)

    def default_fields(view: DEFAULT_VIEW) = fields(view: view)

    # rows — the live list of a view, filtered by `filter_query` as plain text
    # (number, destination, channel…; the same filter as the /fswapi page).
    # Cursors are ignored: the whole list is replaced on every load.
    def rows(view: DEFAULT_VIEW, filter_query: nil, limit: 100, before_id: nil, since_id: nil, ts_from: nil, ts_to: nil, now: Time.current)
      return [] unless self.class.view(view)&.dig(:table)

      data = FswapiPageData.new(server: @server, view: view, q: filter_query)
      list = data.rows

      error = data.list_error

      raise FetchError, error if error

      columns = Fswapi::Format.columns(view)

      list.first(limit).each_with_index.map do |row, i|
        columns.each_with_object({"id" => i + 1}) do |col, out|
          out[col[:field]] = col[:value].call(row, now).to_s.presence
        end
      end
    end

    # series — a view's history from the warehouse, as chart points
    # ([{ts:, value:, formatted:}]) over the dashboard's window.
    def series(view:, range:, interval:, from: nil, until_: nil)
      metric = self.class.view(view)&.dig(:metric)

      return [] unless metric

      MetricsData.new(nil, @server).points_for(
        source: "fswapi", metric: metric, range: range, interval: interval, from: from, until_: until_
      )
    end
  end
end
