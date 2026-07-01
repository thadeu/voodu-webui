# frozen_string_literal: true

# DataTable::LogsSource — the generic "pod logs" source for the DataTable.
# It tabulates a workload's log lines (the same NDJSON warehouse the /logs
# Analytics screen reads via LogTail::Reader), so a Table panel can live in a
# dashboard next to the charts. Unlike Hep3Source (SQLite), the backing store
# is line-oriented files, so:
#
#   - the row cursor "id" is the line's timestamp in MICROSECONDS (ts is the
#     natural monotonic key; before_id pages older, since_id live-appends);
#   - the filter is the LogQuery DSL (@message like /re/, and/or/not) applied
#     by the Reader's matcher — the SAME language as /logs, not SQL;
#   - the workload's replicas are resolved from the warehouse itself by the
#     `<scope>-<resource>.` container-name prefix (no external pod list).
#
# Implements the DataTable::Registry contract: available_for? / label /
# short_label / view_options / fields / default_fields / rows / live_stream.
module DataTable
  class LogsSource
    LABEL = "Pod logs"
    SHORT_LABEL = "Logs"

    VIEWS = [{key: "lines", label: "Lines", realtime: "append"}].freeze
    DEFAULT_VIEW = "lines"

    FIELDS = %w[ts level stream message].freeze
    DEFAULT_FIELDS = %w[ts level stream message].freeze

    # A window is always in play (the range picker), but guard huge scans.
    DEFAULT_LOOKBACK = 3600 # seconds, when no range window is passed
    SCAN_CAP = 5000

    def self.label = LABEL

    def self.short_label = SHORT_LABEL

    # available_for? — every island has logs; the generic Table type is
    # always offered (unlike hep3, which is plugin-gated).
    def self.available_for?(_island) = true

    def self.view_options
      VIEWS.map { |v| {key: v[:key], label: v[:label], fields: FIELDS} }
    end

    def self.from_params(island:, params:)
      scope = params[:scope].to_s
      name = params[:name].to_s
      return nil if scope.empty? || name.empty?

      new(island: island, scope: scope, name: name)
    end

    def initialize(island:, scope:, name:)
      @island = island
      @scope = scope
      @name = name
    end

    def views = VIEWS

    def default_view = DEFAULT_VIEW

    def fields(view: DEFAULT_VIEW) = FIELDS

    def default_fields(view: DEFAULT_VIEW) = DEFAULT_FIELDS

    # live_stream — nil: the log warehouse has no per-row ActionCable push, so
    # the table live-appends by polling (since_id) instead.
    def live_stream = nil

    def rows(view: DEFAULT_VIEW, filter_query: nil, limit: 100, before_id: nil, since_id: nil, ts_from: nil, ts_to: nil)
      until_ = if before_id
        micros_to_time(before_id)
      else
        (ts_to ? Time.at(ts_to) : Time.current)
      end
      from = if since_id
        micros_to_time(since_id)
      else
        (ts_from ? Time.at(ts_from) : until_ - DEFAULT_LOOKBACK)
      end
      return [] if from >= until_

      collected = read_lines(from: from, until_: until_, filter_query: filter_query, limit: limit)

      collected
        .sort_by { |r| r["id"] }
        .reverse
        .first(limit)
    end

    private

    # pods — the workload's replica container names, resolved from the
    # warehouse by the `<scope>-<resource>.` prefix (exact match too, for
    # single-container kinds). Empty → the Reader would scan every pod, so we
    # pass the resolved list explicitly (and bail to [] when none match).
    def pods
      prefix = "#{@scope}-#{@name}."
      exact = "#{@scope}-#{@name}"

      LogTail::FilePath.list_pods(@island.id).select { |p| p == exact || p.start_with?(prefix) }
    end

    def read_lines(from:, until_:, filter_query:, limit:)
      instances = pods
      return [] if instances.empty?

      rows = []

      LogTail::Reader.each_line(
        island_id: @island.id, pods: instances, from: from, until_: until_,
        content_search: filter_query.to_s.presence, limit: [limit * 4, SCAN_CAP].min
      ) do |pod, hash|
        rows << line_row(pod, hash)
      end

      rows
    end

    def line_row(pod, hash)
      ts = (hash["ts"] || hash[:ts]).to_s

      {
        "id" => micros(ts),
        "ts" => ts,
        "pod" => pod,
        "level" => (hash["level"] || hash[:level]).to_s,
        "stream" => (hash["stream"] || hash[:stream]).to_s,
        "message" => (hash["msg"] || hash[:msg]).to_s
      }
    end

    # micros — a line's timestamp as an integer microsecond cursor. 0 when
    # unparseable (sorts oldest; never raises).
    def micros(ts)
      (Time.zone.parse(ts).to_f * 1_000_000).round
    rescue ArgumentError, TypeError
      0
    end

    def micros_to_time(id)
      Time.at(id.to_i / 1_000_000.0)
    end
  end
end
