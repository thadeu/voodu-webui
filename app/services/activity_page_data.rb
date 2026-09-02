# frozen_string_literal: true

# ActivityPageData — everything the /activity screen renders, built once per
# request from the local warehouse.
#
# Reads SQL, never the controller. That is the whole reason the trail is
# warehoused: the screen has to open when the box is DOWN, which is exactly
# when somebody wants to know what happened to it. A page that fetched from
# the controller would go blank at the only moment it matters.
#
# Filters are all optional and compose. Every combination the screen offers
# lands on an index declared in the migration — nothing here scans.
class ActivityPageData
  # RANGES — the presets the filter bar offers, plus a custom window the picker
  # adds on top. 30 days is the preset ceiling because that is the controller's
  # own default retention: offering 90 would promise a window the box does not
  # keep. A custom range can still reach further back — it just finds nothing,
  # which is an honest answer rather than a promise.
  RANGES = {
    "1h" => 1.hour,
    "24h" => 24.hours,
    "7d" => 7.days,
    "30d" => 30.days
  }.freeze

  DEFAULT_RANGE = "7d"

  # PER_PAGE — an operator scanning for "what happened this week" reads a page
  # at a time; 50 rows is roughly two screens, which is where paging stops
  # feeling like work.
  PER_PAGE = 25

  # The vocabularies the filter bar draws its chips from. Declared here rather
  # than derived from the data so a filter for `rollback` still appears on a
  # server that has never had one — an empty result is an answer, a missing
  # chip is a screen that looks broken.
  ACTIONS = %w[apply restart delete rollback config.set config.delete].freeze
  ORIGINS = %w[cli ssh receive_pack api deploy_plane].freeze
  STATUSES = [
    ActivityAction::IN_FLIGHT,
    "succeeded",
    "failed",
    "partial",
    ActivityAction::UNKNOWN
  ].freeze

  attr_reader :server

  def initialize(server, params = {}, now: Time.current)
    @server = server
    @params = (params || {}).to_h.symbolize_keys
    @now = now
  end

  # rows — the current page, newest first.
  #
  # CURSOR paging, not offset, and the reason is this list specifically: the
  # poller inserts at the TOP every thirty seconds and the frame reloads
  # itself. Under OFFSET everything shifts down between renders, so page two
  # re-shows rows already read on page one. A cursor names a row, and a row
  # does not move.
  #
  # It also drops the COUNT(*) that "page N of M" needed — a second full scan
  # per render, and with the text search a second scan of the whole window,
  # spent entirely on drawing a denominator.
  #
  # Memoised as an Array, not a relation: the view walks it more than once
  # (grouping by day) and a relation would re-query each time.
  def rows
    @rows ||= if before_cursor
      # Walking BACKWARDS: take the oldest rows newer than the boundary, then
      # flip so the page still reads newest-first.
      filtered.newer_than(*before_cursor).oldest_first.limit(PER_PAGE).to_a.reverse
    elsif after_cursor
      filtered.older_than(*after_cursor).recent_first.limit(PER_PAGE).to_a
    else
      filtered.recent_first.limit(PER_PAGE).to_a
    end
  end

  def any?
    rows.any?
  end

  # has_newer? / has_older? — whether the arrows lead anywhere.
  #
  # `exists?` and not a count: it is `SELECT 1 … LIMIT 1`, which stops at the
  # first hit. Even under the text search — the one filter that cannot use an
  # index — it stops on the first match instead of scanning to the end to
  # produce a number nothing displays.
  def has_newer?
    return false if rows.empty?

    @has_newer = filtered.newer_than(rows.first.ts_epoch, rows.first.id).exists? unless defined?(@has_newer)
    @has_newer
  end

  def has_older?
    return false if rows.empty?

    @has_older = filtered.older_than(rows.last.ts_epoch, rows.last.id).exists? unless defined?(@has_older)
    @has_older
  end

  def newest_cursor = rows.first&.cursor

  def oldest_cursor = rows.last&.cursor

  # first_page? — asked by the "jump to newest" control, which is pointless
  # when you are already there. Derived from the data, not from the absence of
  # a cursor: a `before` walk can land back on the newest page, and the arrow
  # should go quiet when it does.
  def first_page? = !has_newer?

  # empty_because — why the table has nothing, which is not one question.
  #
  # "This server has never recorded an action" and "your filters match nothing"
  # need different words: the first is a setup problem the operator may need to
  # act on, the second is a filter they can widen. Saying "no activity" to both
  # sends the first one looking in the wrong place.
  def empty_because
    return nil if any?

    filters_applied? ? :filtered : :never_recorded
  end

  def before_cursor = @before_cursor ||= ActivityAction.parse_cursor(@params[:before])

  def after_cursor = @after_cursor ||= ActivityAction.parse_cursor(@params[:after])

  def filters_applied?
    selected_actions.any? || selected_origins.any? || selected_statuses.any? ||
      selected_scope.present? || query.present? || range != DEFAULT_RANGE
  end

  # ── Filter state, as the bar renders it ─────────────────────────

  def selected_actions = @selected_actions ||= list_param(:act) & ACTIONS

  def selected_origins = @selected_origins ||= list_param(:origin) & ORIGINS

  def selected_statuses = @selected_statuses ||= list_param(:status) & STATUSES

  def selected_scope = @selected_scope ||= @params[:scope].to_s.strip.presence

  # query — the free-text box. Any word, anywhere in the row.
  def query = @query ||= @params[:q].to_s.strip.presence

  # The window, parsed by the same helper the alert history and log search use.
  # Custom ranges are its whole reason for existing: once the operator picks
  # Custom it STAYS custom even with a bound missing, because falling back to a
  # preset there silently discards what they asked for.
  def window
    @window ||= TimeWindowParser.new(
      @params,
      ranges: RANGES,
      default_range: DEFAULT_RANGE,
      # A blank `from` on a custom window falls back a day before `until`:
      # operator actions are spread over days, not the minutes logs are.
      custom_blank_from: 1.day
    )
  end

  def range = window.range

  def custom_range? = window.custom?

  def from_iso = window.from_iso

  def until_iso = window.until_iso

  def range_keys = RANGES.keys

  # scopes — the scope values this server has actually recorded, for the
  # picker. Derived from the data (unlike actions and origins) because a scope
  # is the operator's own word: there is no fixed list to draw from.
  #
  # Bounded and un-windowed on purpose: a scope the operator used last month
  # should still be selectable while they are looking at the last hour, or the
  # picker would empty out exactly when they widen the search.
  def scopes
    @scopes ||= base.where.not(scope: [nil, ""]).distinct.limit(50).pluck(:scope).compact.sort
  end

  # in_flight_count — the badge on the "running" chip, and the reason the page
  # polls. Counted over the whole server, not the current filter: an operator
  # filtered down to failures still wants to know something is running.
  def in_flight_count
    @in_flight_count ||= base
      .in_flight
      .where(ts_epoch: (@now - ActivityAction::ORPHAN_AFTER).to_i..)
      .count
  end

  # ── Query ───────────────────────────────────────────────────────

  private

  # base — every row for this server, and the only place server_id is applied.
  # ActivityAction demands a Server object rather than an id (see ServerScoped)
  # precisely so this cannot be reached with a number from a URL.
  def base
    ActivityAction.where(server_id: ActivityAction.server_id_of(@server))
  end

  def filtered
    @filtered ||= begin
      rel = base.range(from: window.from, to: window.until_)
      rel = rel.with_action(selected_actions) if selected_actions.any?
      rel = rel.with_origin(selected_origins) if selected_origins.any?
      rel = rel.with_scope(selected_scope) if selected_scope
      rel = rel.merge(ActivityAction.with_status(selected_statuses, now: @now)) if selected_statuses.any?
      rel = rel.matching(query) if query
      rel
    end
  end

  # list_param accepts both `?act=apply&act=restart` and `?act=apply,restart` —
  # the first is what the filter form submits, the second is what somebody
  # types or shares in a link.
  #
  # `act` and not `action`: Rails owns `params[:action]` (the router writes the
  # controller action into it), so a query string named `action` is clobbered
  # before this ever sees it.
  def list_param(key)
    raw = @params[key]

    values = case raw
    when Array then raw
    else raw.to_s.split(",")
    end

    values.map { |v| v.to_s.strip }.reject(&:empty?).uniq
  end
end
