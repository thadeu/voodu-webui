# frozen_string_literal: true

# DataTable::Hep3Source — the HEP3 SIP-capture source for the generic
# DataTable. Reads the local read model (HepMessage) for one reader pod
# (scope, name) of an server, and offers three VIEWS the operator picks
# in the panel's second dropdown:
#
#   messages — one row per SIP message (the raw tail).      [live-append]
#   calls    — one row per call (grouped by corr_id):       [refresh]
#              parties, message count, time span, result hint.
#   errors   — messages with a 4xx/5xx response only.       [live-append]
#
# Implements the DataTable::Registry contract: views / fields /
# default_fields / rows / live_stream. Schema-less — rows are flat
# string-keyed hashes; every row carries "id", the cursor the table uses
# for infinite scroll (before_id) and, on append views, live-append
# (since_id). For calls the "id" is the group's MAX(ts_epoch).
module DataTable
  class Hep3Source
    VIEWS = [
      {key: "messages", label: "Messages", realtime: "append"},
      {key: "calls", label: "Calls", realtime: "refresh"},
      {key: "errors", label: "Errors", realtime: "append"}
    ].freeze

    DEFAULT_VIEW = "messages"

    # Display labels for the panel builder's source picker. `label` is the
    # full name; `short_label` prefixes the combined "HEP3 — Messages"
    # source·view options.
    LABEL = "HEP3 — SIP capture"
    SHORT_LABEL = "HEP3"

    def self.label = LABEL

    def self.short_label = SHORT_LABEL

    # available_for? — only offer this source when the server's controller
    # has the voodu-hep3 plugin installed (same gate as everything hep3).
    def self.available_for?(server) = server.plugin_installed?("hep3")

    # view_options — each view's {key, label, fields} for the builder. The
    # field list drives the panel's filter-field dropdown (which fields the
    # operator can pre-filter on), and differs per view (calls are grouped).
    def self.view_options
      VIEWS.map { |v| {key: v[:key], label: v[:label], fields: fields_for(v[:key])} }
    end

    def self.fields_for(view)
      (view.to_s == "calls") ? CALL_FIELDS : MESSAGE_FIELDS
    end

    # Message/error rows expose the SIP record fields (raw_sip is shown in
    # the call-flow drawer, not a cell).
    MESSAGE_FIELDS = %w[
      ts method cseq response_code from_user to_user ruri
      src_ip src_port dst_ip dst_port call_id corr_id x_cid user_agent node_id
    ].freeze

    MESSAGE_DEFAULTS = %w[ts cseq response_code from_user to_user src_ip dst_ip call_id].freeze

    # Call rows are the aggregate summary.
    CALL_FIELDS = %w[started_at last_ts from_user to_user methods messages last_code corr_id].freeze
    CALL_DEFAULTS = %w[started_at from_user to_user last_code corr_id].freeze

    ERROR_THRESHOLD = 400

    def self.from_params(server:, params:)
      scope = params[:scope].to_s
      name = params[:name].to_s
      return nil if scope.empty? || name.empty?

      new(server: server, scope: scope, name: name)
    end

    def initialize(server:, scope:, name:)
      @server = server
      @scope = scope
      @name = name
    end

    def views = VIEWS

    def default_view = DEFAULT_VIEW

    # row_action — the per-row drill-down the DataTable renders as a leading
    # icon: opens the SIP call-flow ladder for the row's corr_id (works in
    # every view — messages/calls/errors all carry corr_id). `key` is the
    # row field the value comes from; `event` is the CustomEvent the page
    # host listens for; `icon` is the Heroicon const the cell shows.
    def row_action
      {key: "corr_id", event: "callflow", title: "Open call-flow", icon: "ArrowsRightLeftOutline"}
    end

    def fields(view: DEFAULT_VIEW)
      self.class.fields_for(view)
    end

    def default_fields(view: DEFAULT_VIEW)
      calls?(view) ? CALL_DEFAULTS : MESSAGE_DEFAULTS
    end

    # filter_error — nil when the query is empty or valid; the parse message
    # otherwise. The controller surfaces this instead of silently returning
    # every row — an unparseable filter must never read as "no filter".
    def filter_error(filter_query)
      return nil if filter_query.to_s.strip.empty?

      DataTable::Query.compile(filter_query) { |field| HepMessage.filter_expr(field) }.error
    end

    def rows(view: DEFAULT_VIEW, filter_query: nil, limit: 100, before_id: nil, since_id: nil, ts_from: nil, ts_to: nil)
      where_sql, where_binds = compile_filter(filter_query)

      if calls?(view)
        call_rows(where_sql: where_sql, where_binds: where_binds, limit: limit, before_id: before_id,
          ts_from: ts_from, ts_to: ts_to)
      else
        message_rows(where_sql: where_sql, where_binds: where_binds, limit: limit, before_id: before_id,
          since_id: since_id, min_code: errors?(view) ? ERROR_THRESHOLD : nil, ts_from: ts_from, ts_to: ts_to)
      end
    end

    # count_series — per-bucket COUNT for a chart panel (Area/Radial/Linear on
    # a HEP3 source): how many rows of `view` (matching `filter_query`) land in
    # each bucket of [ts_from, ts_to). Calls count one-per-corr_id; errors count
    # only 4xx/5xx. Returns [[bucket_epoch, count], …] for the sparkline.
    def count_series(ts_from:, ts_to:, bucket:, view: DEFAULT_VIEW, filter_query: nil)
      where_sql, where_binds = compile_filter(filter_query)

      HepMessage.count_series(
        server_id: @server.id, scope: @scope, name: @name,
        ts_from: ts_from, ts_to: ts_to, bucket: bucket,
        where_sql: where_sql, where_binds: where_binds,
        distinct_corr: calls?(view), min_code: errors?(view) ? ERROR_THRESHOLD : nil
      )
    end

    # live_stream — the ActionCable stream the Hep3 poller broadcasts to
    # after inserting new rows for this instance (view-agnostic; the table
    # appends or refreshes per the view's realtime mode).
    def live_stream
      self.class.stream_name(@server.id, @scope, @name)
    end

    def self.stream_name(server_id, scope, name)
      "hep3-rows:#{server_id}:#{scope}:#{name}"
    end

    private

    def calls?(view) = view.to_s == "calls"

    def errors?(view) = view.to_s == "errors"

    # compile_filter — the DataTable filter DSL → [where_sql, binds], using
    # HepMessage's field allowlist as the resolver (fields never injected).
    # Empty query / parse error → no filter.
    def compile_filter(query)
      return [nil, []] if query.to_s.strip.empty?

      compiled = DataTable::Query.compile(query) { |field| HepMessage.filter_expr(field) }

      [compiled.sql, compiled.binds]
    end

    def message_rows(where_sql:, where_binds:, limit:, before_id:, since_id:, min_code:, ts_from: nil, ts_to: nil)
      HepMessage.page(
        server_id: @server.id, scope: @scope, name: @name,
        where_sql: where_sql, where_binds: where_binds,
        limit: limit, before_id: before_id, since_id: since_id, min_code: min_code,
        ts_from: ts_from, ts_to: ts_to
      ).map { |m| message_row(m) }
    end

    def message_row(message)
      message.payload_json
        .except("raw_sip")
        .merge("id" => message.id, "corr_id" => message.corr_id)
    end

    def call_rows(where_sql:, where_binds:, limit:, before_id:, ts_from: nil, ts_to: nil)
      HepMessage.calls_page(
        server_id: @server.id, scope: @scope, name: @name,
        where_sql: where_sql, where_binds: where_binds,
        limit: limit, before_epoch: before_id, ts_from: ts_from, ts_to: ts_to
      ).map { |row| call_row(row) }
    end

    # call_row — maps a CALLS_SELECT tuple to a flat hash. "id" is the
    # group's MAX(ts_epoch) so the table's numeric before_id cursor pages
    # older calls uniformly with the message views.
    def call_row(tuple)
      corr_id, last_epoch, started_at, last_ts, messages, last_code, from_user, to_user, methods = tuple

      {
        "id" => last_epoch,
        "corr_id" => corr_id,
        "started_at" => started_at,
        "last_ts" => last_ts,
        "messages" => messages,
        "last_code" => last_code,
        "from_user" => from_user,
        "to_user" => to_user,
        "methods" => methods.to_s.split(",").reject(&:empty?).join(", ")
      }
    end
  end
end
