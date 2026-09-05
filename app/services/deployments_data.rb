# frozen_string_literal: true

# DeploymentsData — the deploy history of one server, for the Deployments tab.
#
# Reads OUR database and never the box. That is unusual on this dashboard,
# where most screens are a view onto the controller, and it is right here: a
# deployment is a thing that happened to US — a webhook arrived, a job ran, a
# box answered. The controller knows the current state; only we know the
# sequence that produced it.
#
# CURSOR PAGING, not offset, matching Activity. An offset page two is a page
# that shifts under the reader: deploys arrive while they are looking, and
# `OFFSET 30` then re-shows rows they already read. A cursor names a ROW, so
# "older than this one" stays true no matter what lands above it.
class DeploymentsData
  PER_PAGE = 30

  STATUSES = %w[queued running succeeded failed skipped].freeze

  # RANGES — the presets the filter offers. Wider than Activity's because a
  # deployment history is not a firehose: a busy box writes a handful a day,
  # so "the last 90 days" is a page or two rather than a wall, and "when did
  # we last ship this repo" is a question people ask across months.
  RANGES = {
    "24h" => 24.hours,
    "7d" => 7.days,
    "30d" => 30.days,
    "90d" => 90.days
  }.freeze

  # ALL — the escape hatch, and it has to exist here where it does not in
  # Activity: these rows are OURS and never expire, so a default window that
  # hides the first deploy of a repository would hide it forever.
  DEFAULT_RANGE = "30d"

  # PARAMS ARE READ, NEVER PERMITTED — and they are narrowed to a plain hash
  # right here, on the way in.
  #
  # Two reasons, and the second is the one that bites. `params.permit(status:
  # [])` silently DROPS a scalar, so `?status=failed` typed by hand or carried
  # by a link would apply nothing, with no error to notice. And an unpermitted
  # ActionController::Parameters raises the moment anything calls `to_h` on it
  # — which TimeWindowParser does, three layers down.
  #
  # Nothing here is mass-assigned: every value below is compared against a
  # known list or passed to a bound query. Taking the keys we read is both the
  # narrowing and the whole safety story.
  KEYS = %i[status repo q range from until before after].freeze

  def initialize(server:, id: nil, params: {})
    @server = server
    @id = id
    @params = narrow(params)
  end

  attr_reader :server

  # deployment — the one being looked at, or nil.
  #
  # Scoped to the server, always. An id from another org's screen resolves to
  # nil here the same way a made-up one does, so the tenant boundary is the
  # query rather than a check somebody has to remember.
  def deployment
    return nil if @id.blank?

    @deployment ||= @server.deployments.find_by(id: @id)
  end

  # ── filters ────────────────────────────────────────────────────────────

  # Hand-read, never `params.permit`. A multi-value filter declared as
  # `permit(status: [])` silently DROPS a scalar — `?status=failed` from a
  # hand-typed URL or a link would apply nothing, with no error to notice.
  # Nothing here is mass-assigned, so strong params buys nothing either.
  def statuses = @statuses ||= multi(:status) & STATUSES

  def repos_filter = @repos_filter ||= multi(:repo)

  def query = @query ||= @params[:q].to_s.strip

  # nil when the operator asked for everything — the scope then applies no
  # date clause at all.
  def window
    return @window if defined?(@window)

    @window = if range_key == "all"
      nil
    else
      TimeWindowParser.new(@params, ranges: RANGES, default_range: DEFAULT_RANGE).window
    end
  end

  def range_key = @params[:range].presence || DEFAULT_RANGE

  def filtered?
    statuses.any? || repos_filter.any? || query.present? ||
      custom_range? || range_key != DEFAULT_RANGE
  end

  def custom_range? = @params[:from].present? || @params[:until].present?

  # ── the page ───────────────────────────────────────────────────────────

  def rows
    @rows ||= if before_cursor
      # Walking BACKWARDS: take the oldest side of the newer rows, then flip,
      # so the page reads newest-first like every other one.
      scope.newer_than(*before_cursor).oldest_first.limit(PER_PAGE).to_a.reverse
    elsif after_cursor
      scope.older_than(*after_cursor).recent.limit(PER_PAGE).to_a
    else
      scope.recent.limit(PER_PAGE).to_a
    end
  end

  # `exists?`, never COUNT(*). The arrows only need to know whether they lead
  # anywhere, and counting the whole history to answer that is a full scan for
  # a boolean.
  def has_newer?
    return false if rows.empty?

    @has_newer = scope.newer_than(rows.first.created_at, rows.first.id).exists? unless defined?(@has_newer)
    @has_newer
  end

  def has_older?
    return false if rows.empty?

    @has_older = scope.older_than(rows.last.created_at, rows.last.id).exists? unless defined?(@has_older)
    @has_older
  end

  def newest_cursor = rows.first&.cursor

  def oldest_cursor = rows.last&.cursor

  # Whether the "newest" jump leads anywhere. Not the same as having no cursor:
  # a `before` walk can land back on the newest page, and the arrow should go
  # quiet there rather than pointing at where the reader already is.
  def first_page? = !has_newer?

  # ── what the filters offer ─────────────────────────────────────────────

  # Every repository that has EVER deployed here, not only the ones matching
  # the current filter — a filter whose options disappear as you use it is a
  # filter you cannot undo.
  def repo_options
    @repo_options ||= @server.deployments.distinct.pluck(:repo).compact.sort
  end

  def status_counts
    @status_counts ||= @server.deployments.group(:status).count
  end

  def any? = @server.deployments.exists?

  private

  def narrow(params)
    source = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : (params || {})

    source.to_h.symbolize_keys.slice(*KEYS)
  end

  def scope
    rows = @server.deployments
    rows = rows.where(status: statuses) if statuses.any?
    rows = rows.where(repo: repos_filter) if repos_filter.any?
    rows = rows.matching(query) if query.present?
    # `window` is a two-element ARRAY, not a Range — passing it straight to
    # `where` builds `created_at IN (from, until)`, which matches the two
    # boundary instants and nothing between them. It silently returned an
    # empty history.
    rows = rows.where(created_at: window.first..window.last) if window

    rows
  end

  # multi — a filter that may arrive as a scalar OR a list.
  #
  # `?status=failed` and `?status[]=failed&status[]=queued` both have to work:
  # the first is what a person types and what a link carries, the second is
  # what the dropdown submits.
  def multi(key)
    raw = @params[key]

    Array(raw.is_a?(String) ? raw.split(",") : raw).map { |v| v.to_s.strip }.reject(&:empty?).uniq
  end

  def before_cursor = @before_cursor ||= Deployment.parse_cursor(@params[:before])

  def after_cursor = @after_cursor ||= Deployment.parse_cursor(@params[:after])
end
