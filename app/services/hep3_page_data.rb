# frozen_string_literal: true

# Hep3PageData — the /hep3 page: the SIP calls one voodu-hep3 reader captured,
# in the same DataTable the Metrics "Calls" panel uses. That panel answered the
# question, but behind a dashboard somebody had to build first — a new operator
# never looks under Metrics for a list of calls.
#
# The operator picks ONE reader (a voodu-hep3-api deployment). The table reads
# one reader's warehouse rows (DataTable::Hep3Source is keyed by scope + name),
# so a multi-select would promise a merge the source cannot do.
#
# Tabs (Components::UI::WorkspaceTabs): every state lives in the URL, keyed by
# a `ws` (workspace tab) id. A missing or malformed id gets a fresh one, so
# each visit is always in exactly one tab.
#
# The time range is always set: no range param means the default preset, never
# "every call ever captured". The window rides every rows fetch, like on Metrics.
class Hep3PageData
  VIEW = "calls"

  # Panel keys — the data-metric-key the Settings drawer hides / orders by.
  COUNT_PANEL = "calls_count"
  TABLE_PANEL = "calls_table"

  # display_items — the Settings drawer tiles (Views::Metrics::DisplaySettings).
  # One color per metric: --voodu-lime is the SIP calls signal (CLAUDE.md).
  DISPLAY_ITEMS = [
    {metric: COUNT_PANEL, label: "Calls · count", color: "var(--voodu-lime)", section: "resource", unit: "distinct"},
    {metric: TABLE_PANEL, label: "Calls · table", color: "var(--voodu-text-2)", section: "resource", unit: "rows"}
  ].freeze

  # Fewest buckets the sparkline gets, and the smallest bucket: a 1m window
  # still draws a line, a 7d window stays ~60 points of raw SQL.
  SPARK_BUCKETS = 60
  MIN_BUCKET_SECONDS = 5

  # filter_fields — every field the query editor may name (HepMessage's
  # filter allowlist), for its `@` autocomplete and validation.
  def self.filter_fields
    HepMessage::FILTER_COLUMNS.keys + HepMessage::JSON_FILTER_FIELDS
  end

  TAB_ID = /\A[a-z0-9]{8}\z/

  attr_reader :server, :range, :tab_id, :filter_query

  def initialize(server:, scope: nil, name: nil, range: nil, from: nil, until_: nil, tab: nil, q: nil)
    @server = server
    @fresh = !tab.to_s.match?(TAB_ID)
    @tab_id = @fresh ? SecureRandom.alphanumeric(8).downcase : tab.to_s
    @filter_query = q.to_s
    @scope = scope.to_s
    @name = name.to_s
    @range = MetricsPageData::RANGES.key?(range.to_s) ? range.to_s : MetricsPageData::DEFAULT_RANGE
    @from = from
    @until_ = until_
  end

  # readers — one card per reader deployment, NOT per replica: every replica
  # of a reader drains into the same (scope, name) warehouse rows.
  def readers
    @readers ||= reader_pods
      .group_by { |pod| [pod.scope, pod.resource_name] }
      .map { |(scope, name), pods| reader_card(scope, name, pods) }
      .sort_by { |reader| [reader[:scope], reader[:name]] }
  end

  # selected — the reader in the URL, only when it really runs on this server.
  # A hand-typed scope/name that names nothing falls back to the picker, never
  # to an empty table that reads as "no calls".
  def selected
    return @selected if defined?(@selected)

    @selected = readers.find { |reader| reader[:scope] == @scope && reader[:name] == @name }
  end

  def selected? = !selected.nil?

  # custom? — a valid explicit window is in play (overrides the preset).
  def custom?
    @from.present? && @until_.present?
  end

  def from_iso = @from&.utc&.iso8601

  def until_iso = @until_&.utc&.iso8601

  def fields = DataTable::Hep3Source.fields_for(VIEW)

  def default_fields = DataTable::Hep3Source::CALL_DEFAULTS

  def row_action = source.row_action

  # count — the distinct calls in the window: {total:, points:}. Every call
  # counts once, in the bucket it starts in, so the sparkline adds up to the
  # total. nil without a reader.
  def count
    return nil unless selected?

    @count ||= begin
      from, to = window
      bucket = bucket_seconds(to - from)
      series = source.call_count_series(ts_from: from, ts_to: to, bucket: bucket, filter_query: @filter_query)
      points = densify(series.to_h, from, to, bucket)

      {total: points.sum { |p| p[:value] }, points: points}
    end
  end

  # window — [from, to] epoch seconds: the explicit span, or the last `range`
  # up to now (the count card re-reads it on every poll).
  def window
    return [@from.to_i, @until_.to_i] if custom?

    now = Time.current.to_i

    [now - (MetricsPageData.range_to_ms(@range) / 1000), now]
  end

  def range_ms
    from, to = window

    (to - from) * 1000
  end

  # table_key — namespaces the DataTable's saved columns / widths / live state
  # and filter per TAB: two tabs on one reader keep their own filters. Starts
  # with TABLE_KEY_PREFIX + tab id, so closing a tab can clear its keys.
  TABLE_KEY_PREFIX = "hep3-page:"

  def table_key
    "#{TABLE_KEY_PREFIX}#{@tab_id}:#{selected[:scope]}:#{selected[:name]}"
  end

  # fresh? — the visit named no tab (the sidebar link). Only the browser knows
  # the open tabs, so it decides: reopen the first one, or keep this new id
  # as the first tab (Components::UI::WorkspaceTabs).
  def fresh? = @fresh

  # tab_label — what the tab strip shows: the reader, or "New tab" while the
  # tab is still on the picker.
  def tab_label
    return "New tab" unless selected?

    "#{selected[:scope]} · #{selected[:name]}"
  end

  private

  def source
    @source ||= DataTable::Hep3Source.new(server: @server, scope: @scope, name: @name)
  end

  def bucket_seconds(span)
    [(span / SPARK_BUCKETS.to_f).ceil, MIN_BUCKET_SECONDS].max
  end

  # densify — [[bucket_epoch, n]] → gap-free [{ts:, value:, formatted:}] over
  # [from, to), so empty buckets draw as 0 instead of a broken line.
  def densify(counts, from, to, bucket)
    points = []
    b = (from / bucket) * bucket

    while b < to
      n = counts[b].to_i

      points << {ts: Time.at(b).utc.iso8601, value: n, formatted: n.to_s}
      b += bucket
    end

    points
  end

  def reader_pods
    @server.pods.select { |pod| pod.image.start_with?(Server::HEP3_READER_IMAGE) && pod.scope.present? && pod.resource_name.present? }
  end

  def reader_card(scope, name, pods)
    {
      scope: scope,
      name: name,
      kind: pods.first.kind,
      replicas: pods.size,
      running: pods.any?(&:running?)
    }
  end
end
