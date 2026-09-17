# frozen_string_literal: true

# WebhookReceiptsData — every delivery that arrived, for the Webhooks tab.
#
# Reads OUR database and never a provider. The question this answers is "did
# GitHub call, and what did we do about it" — and only we can answer the second
# half. The provider's own delivery log answers the first, from the other side.
#
# CURSOR PAGING, not offset, matching Activity and Deployments: deliveries
# arrive while somebody is reading, and `OFFSET 30` then re-shows rows they
# already read.
class WebhookReceiptsData
  PER_PAGE = 30

  RANGES = {
    "24h" => 24.hours,
    "7d" => 7.days,
    "30d" => 30.days,
    "90d" => 90.days
  }.freeze

  DEFAULT_RANGE = "7d"

  # Read, never permitted, and narrowed on the way in. `permit(status: [])`
  # silently drops a scalar, so `?status=failed` from a hand-typed URL applies
  # nothing — and an unpermitted Parameters raises the moment TimeWindowParser
  # calls `to_h` on it.
  KEYS = %i[status provider reference q range from until before after].freeze

  def initialize(org:, server: nil, id: nil, params: {})
    @org = org
    @server = server
    @id = id
    @params = narrow(params)
  end

  attr_reader :org, :server

  def receipt
    return nil if @id.blank?

    @receipt ||= scope_for_org.find_by(id: @id)
  end

  # ── filters ────────────────────────────────────────────────────────────

  def statuses = @statuses ||= multi(:status) & Webhook::Receipt::STATUSES.keys

  def providers = @providers ||= multi(:provider) & Webhook::Receipt::PROVIDERS

  def references = @references ||= multi(:reference)

  def query = @query ||= @params[:q].to_s.strip

  def range_key = @params[:range].presence || DEFAULT_RANGE

  def custom_range? = @params[:from].present? || @params[:until].present?

  def window
    return @window if defined?(@window)

    @window = if range_key == "all"
      nil
    else
      TimeWindowParser.new(@params, ranges: RANGES, default_range: DEFAULT_RANGE).window
    end
  end

  def filtered?
    statuses.any? || providers.any? || references.any? ||
      query.present? || custom_range? || range_key != DEFAULT_RANGE
  end

  # ── the page ───────────────────────────────────────────────────────────

  def rows
    @rows ||= if before_cursor
      scope.newer_than(*before_cursor).oldest_first.limit(PER_PAGE).to_a.reverse
    elsif after_cursor
      scope.older_than(*after_cursor).recent.limit(PER_PAGE).to_a
    else
      scope.recent.limit(PER_PAGE).to_a
    end
  end

  def has_newer?
    return false if rows.empty?

    @has_newer = scope.newer_than(rows.first.received_at, rows.first.id).exists? unless defined?(@has_newer)
    @has_newer
  end

  def has_older?
    return false if rows.empty?

    @has_older = scope.older_than(rows.last.received_at, rows.last.id).exists? unless defined?(@has_older)
    @has_older
  end

  def newest_cursor = rows.first&.cursor

  def oldest_cursor = rows.last&.cursor

  def first_page? = !has_newer?

  # ── what the filters offer ─────────────────────────────────────────────

  def status_counts = @status_counts ||= scope_for_org.group(:status).count

  def reference_options
    @reference_options ||= scope_for_org.distinct.pluck(:reference).compact_blank.sort
  end

  def any? = scope_for_org.exists?

  # trouble_count — what an operator is usually hunting for, in the window
  # they are looking at. Drawn on the rail so the tab says whether it is worth
  # opening.
  def trouble_count = @trouble_count ||= scope.trouble.count

  private

  # SCOPED TO THE ORG, and nullable org_id is exactly why this needs saying: a
  # delivery that failed its signature, or that matched no server, has no org
  # we could name. Those rows belong to the INSTALLATION, not to a customer —
  # so they are visible to anyone who can read this screen, and they carry no
  # payload for a refused signature.
  #
  # A delivery that DID resolve an org is fenced to it.
  #
  # AND TO THE SERVER, when the screen is a server's. The installation is one
  # per account, so every push GitHub sends reaches this table once — and
  # showing the lot under a database box read as that box having a deploy
  # history it never had. A delivery belongs on this server's tab when it
  # produced a deployment here, or names a repository listed here (so a
  # "nothing matched" for your own repository still shows up where you look
  # for it). Two kinds stay visible on every server, because they belong to
  # nobody and somebody has to see them: a delivery naming no repository at
  # all (an `installation` event, a refused signature), and the trouble
  # outcomes — no server listed it, refused, errored — which are exactly the
  # rows an operator on the wrong tab needs to find.
  def scope_for_org
    rows = Webhook::Receipt.where(org_id: [nil, @org&.id])
    return rows if @server.nil?

    rows.where(
      "webhook_receipts.reference IS NULL OR webhook_receipts.reference = '' " \
      "OR webhook_receipts.status IN (:trouble) " \
      "OR LOWER(webhook_receipts.reference) IN (:listed) " \
      "OR webhook_receipts.id IN (SELECT webhook_receipt_id FROM deployments WHERE server_id = :server_id)",
      trouble: Webhook::Receipt::TROUBLE, listed: listed_repos, server_id: @server.id
    )
  end

  # listed_repos — the repositories that deploy to this server, lower-cased
  # for the comparison above (GitHub is case-insensitive about names).
  def listed_repos
    @listed_repos ||= begin
      integration = Integration::Record.active.find_by(org: @org, provider: "github")
      names = integration ? integration.repos_for_server(@server).map { |entry| entry.repo.to_s.downcase } : []
      names.presence || [""]
    end
  end

  def scope
    rows = scope_for_org
    rows = rows.where(status: statuses) if statuses.any?
    rows = rows.where(provider: providers) if providers.any?
    rows = rows.where(reference: references) if references.any?
    rows = rows.matching(query) if query.present?

    # `window` is a two-element ARRAY, not a Range — passing it straight to
    # `where` builds `received_at IN (from, until)`, which matches the two
    # boundary instants and nothing between them.
    rows = rows.where(received_at: window.first..window.last) if window

    rows
  end

  def narrow(params)
    source = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : (params || {})

    source.to_h.symbolize_keys.slice(*KEYS)
  end

  def multi(key)
    raw = @params[key]

    Array(raw.is_a?(String) ? raw.split(",") : raw).map { |v| v.to_s.strip }.reject(&:empty?).uniq
  end

  def before_cursor = @before_cursor ||= parse_cursor(@params[:before])

  def after_cursor = @after_cursor ||= parse_cursor(@params[:after])

  def parse_cursor(raw)
    ts, id = raw.to_s.split(":")

    return nil if ts.blank? || id.blank?

    [Time.zone.at(ts.to_f), id.to_i]
  end
end
