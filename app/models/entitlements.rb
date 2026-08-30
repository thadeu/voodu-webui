# frozen_string_literal: true

# Entitlements — what this deployment may do, in one table.
#
# Same shape as Permissions, and deliberately a DIFFERENT axis from it. A
# permission answers "who are you inside this org"; an entitlement answers "what
# did this installation buy". Mixing them makes both unreadable — a member who
# cannot invite and an unlicensed install that cannot invite fail for unrelated
# reasons and deserve unrelated messages.
#
# The free tier is the DEFAULT, not a penalty: FREE is what an install gets with
# no licence, and it is a complete product. What Enterprise buys is scale —
# more than one org, people to invite, a longer window, and the control plane in
# your own Postgres.
#
# `nil` means no limit. Except for retention, which never means that: see below.
class Entitlements
  FREE = {
    accounts: 1,
    orgs: 1,
    member_invites: 0,
    retention_days: 3,
    postgres: false
  }.freeze

  # What a licence grants when it does not say otherwise. A token may narrow or
  # widen any of these by naming them in its `ent` claim.
  #
  # retention_days is 90 rather than nil ON PURPOSE. The warehouse is SQLite on
  # a volume, so "unlimited retention" is a disk that fills and a container that
  # dies — selling it would be selling an outage on a delay. Enterprise gets a
  # number it can raise knowingly, not a promise nobody can keep.
  LICENSED = {
    accounts: nil,
    orgs: nil,
    member_invites: nil,
    retention_days: 90,
    postgres: true
  }.freeze

  def self.current(license = LicenseToken.current)
    new(license)
  end

  def initialize(license)
    @license = license || LicenseToken.new(status: :none)
  end

  attr_reader :license

  # The effective table. An unlicensed, lapsed or unverifiable install reads
  # FREE — which is why none of those states can break anything: the free tier
  # is a place the app already knows how to be.
  def table
    @table ||= license.entitled? ? LICENSED.merge(license.granted.slice(*LICENSED.keys)) : FREE
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

  def free? = table == FREE

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

  def room_for_another_org? = within?(:orgs, ::Org.count)

  def room_for_another_account? = within?(:accounts, ::Account.count)

  # An invitation is a membership somebody was invited into — which is exactly
  # what invited_by records. Counting those rather than all memberships keeps
  # the owner each org is created with from consuming a seat.
  def room_for_another_invite?
    within?(:member_invites, ::Org::Membership.where.not(invited_by_id: nil).count)
  end
end
