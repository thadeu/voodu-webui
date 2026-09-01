class Entitlements
  # Two questions, two sources. Keeping them apart is what makes one counting
  # model work for every kind of installation.
  #
  #   the TIER says what the BOX is        → how many accounts fit, and whether
  #                                          the control plane may be Postgres
  #   the PLAN says what an ACCOUNT bought → orgs, invited people, history
  #
  # Postgres sits with the box on purpose: whoever deployed it chose the
  # database, and it is not a thing a customer of a hosted service can pick.
  # Everything else is per-account, so a limit means the same thing whether one
  # customer or a hundred share the installation — and there is no second
  # counting mode that only one deployment shape ever exercises.

  # How many accounts an installation may hold.
  #
  # Enterprise is capped at one, deliberately. It is an upgrade of ONE account
  # to unlimited orgs, bought to run on the buyer's own infrastructure — not a
  # licence to operate a service of their own on top of Voodu.
  ACCOUNTS_BY_TIER = {"free" => 1, "enterprise" => 1, "unlimited" => nil}.freeze

  # What a plan grants. Free is the same everywhere: a customer of the hosted
  # service on the free plan gets exactly what somebody running it themselves
  # gets, which is the only version of "free" that needs explaining once.
  FREE_PLAN = {orgs: 1, member_invites: 0, retention_days: 3}.freeze
  PRO_PLAN = {orgs: nil, member_invites: nil, retention_days: 90}.freeze

  # Kept for the callers that still ask about the installation as a whole.
  FREE = FREE_PLAN.merge(accounts: 1, postgres: false).freeze
  LICENSED = PRO_PLAN.merge(accounts: 1, postgres: true).freeze

  # Current.license, not LicenseToken.current: resolving verifies an RSA
  # signature and reads the database, and several things per request want to
  # know the tier. Current memoises it for the request and Rails clears it
  # between them, so a licence activated mid-session still lands on the next.
  def self.current(license = Current.license)
    new(license)
  end

  # for(account) — what governs this account, on any installation.
  #
  # One path now. The tier decides how many accounts fit and whether Postgres
  # is allowed; the account's plan decides everything else, and the plan is
  # resolved the same way whether one customer or a hundred share the box.
  def self.for(account, license = Current.license)
    new(license, account: account)
  end

  def initialize(license, account: nil)
    @license = license || LicenseToken.new(status: :none)
    @account = account
  end

  attr_reader :license, :account

  def tier = license.tier

  # Which plan governs this account.
  #
  # On the hosted service the account bought one. Anywhere else there is a
  # single account and the box's own licence is what upgraded it — an
  # Enterprise licence IS that account's pro plan, which is what "upgrade to
  # unlimited orgs on my own infrastructure" means.
  def plan
    return account&.plan || LicenseToken::DEFAULT_PLAN if tier == "unlimited"

    license.entitled? ? "pro" : LicenseToken::DEFAULT_PLAN
  end

  def pro? = plan == "pro"

  # What a limit is measured against.
  #
  # Per account, always. `accounts` is the exception and cannot be otherwise —
  # "how many accounts exist on this box" has no per-account version.
  def scope_for(capability)
    case capability
    when :accounts then ::Account.count
    when :orgs then account ? account.orgs.count : ::Org.count
    when :member_invites then invite_count
    else 0
    end
  end

  def table
    @table ||= begin
      base = pro? ? PRO_PLAN : FREE_PLAN
      granted = plan_grants

      # The tier's account cap is a DEFAULT, not a wall: an explicit grant in
      # the licence lifts it, so a multi-account Enterprise can be sold on
      # purpose rather than requiring a new tier to exist.
      accounts = granted.key?(:accounts) ? granted[:accounts] : ACCOUNTS_BY_TIER.fetch(tier, 1)

      base.merge(granted.slice(*PRO_PLAN.keys))
        .merge(accounts: accounts, postgres: license.entitled?)
    end
  end

  def limit(capability) = table[capability]

  # For the boolean entitlements. Kept separate from within? on purpose: `nil`
  # means "no limit" for a count and would read as a denial here, so one method
  # answering both questions gets one of them wrong.
  def enabled?(capability) = table[capability] == true

  # within? — may one more be created? Unknown capabilities deny, like
  # Permissions: a typo must not silently grant.
  def within?(capability, current_count)
    return false unless table.key?(capability)

    max = table[capability]
    return true if max.nil?

    current_count < max
  end

  def retention_days = table.fetch(:retention_days)

  def postgres? = table.fetch(:postgres) == true

  # Whether the adapter actually in use is one this installation did not buy.
  # Takes the adapter name so the decision is a pure function — the alternative
  # buries it behind a live connection and makes it untestable anywhere the test
  # database is not Postgres, which is everywhere CI runs.
  def unlicensed_adapter?(adapter)
    !postgres? && adapter.to_s.start_with?("postgres")
  end

  # Asks the plan, not the shape of the table. Comparing whole hashes broke the
  # moment an entitlement override made a free account's table non-identical to
  # FREE — the question is "did anybody pay", and the plan is the answer.
  def free? = !pro?

  # ── The three questions the creation points ask ────────────────────────
  #
  # Counting lives here rather than in the controllers because the architecture
  # lint (test/architecture/tenant_scoping_test.rb) forbids bare model
  # constants under app/controllers — a rule worth keeping, since a bare
  # `Org.count` and a bare `Org.find` look identical in a diff and only one of
  # them is a tenant-scoping hole.
  #
  # Counts are per INSTALLATION, not per account: the licence is bought by
  # whoever runs this container, and "one org" means this deployment has one.

  def room_for_another_org? = within?(:orgs, scope_for(:orgs))

  def room_for_another_account? = within?(:accounts, scope_for(:accounts))

  # An invitation is a membership somebody was invited into — which is exactly
  # what invited_by records. Counting those rather than all memberships keeps
  # the owner each org is created with from consuming a seat.
  def room_for_another_invite?
    within?(:member_invites, scope_for(:member_invites))
  end

  private

  # Entitlement overrides ride on whichever licence granted the plan: the
  # account's on the hosted service, the box's everywhere else. A customer who
  # negotiated something specific gets it without a new plan name existing.
  def plan_grants
    return account&.plan_license&.granted || {} if tier == "unlimited"

    license.granted
  end

  def invite_count
    return ::Org::Membership.where.not(invited_by_id: nil).count if account.nil?

    ::Org::Membership.where(org: account.orgs).where.not(invited_by_id: nil).count
  end
end
