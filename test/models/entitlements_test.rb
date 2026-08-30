# frozen_string_literal: true

require "test_helper"

# The free tier is the DEFAULT, and every path that is not a live licence must
# land on it — no licence, a lapsed one, a forged one. That is what makes the
# licence safe to add: the app already knows how to be the free tier, so every
# failure mode is a place it can be rather than an error it hits.
class EntitlementsTest < ActiveSupport::TestCase
  def licensed(ent = {}, status: :valid)
    LicenseToken.new(status: status, claims: {"sub" => "acme", "ent" => ent})
  end

  test "no licence is the free tier" do
    e = Entitlements.new(LicenseToken.new(status: :none))

    assert e.free?
    assert_equal 1, e.limit(:orgs)
    assert_equal 0, e.limit(:member_invites)
    assert_equal 3, e.retention_days
    assert_not e.postgres?
  end

  # Each of these is a way a licence can fail. None may grant anything, and all
  # must land on exactly the same table as having no licence at all.
  test "lapsed and unverifiable licences read as the free tier" do
    %i[lapsed invalid].each do |status|
      e = Entitlements.new(licensed({"orgs" => 99, "postgres" => true}, status: status))

      assert e.free?, "#{status} must not grant anything"
      assert_equal 1, e.limit(:orgs)
      assert_not e.postgres?
    end
  end

  test "a live licence lifts the limits" do
    e = Entitlements.new(licensed)

    assert_not e.free?
    assert_nil e.limit(:orgs), "nil means no limit"
    assert e.postgres?
    assert_equal 90, e.retention_days, "the documented Enterprise default"
  end

  test "grace still grants, because that is what grace is for" do
    assert Entitlements.new(licensed({}, status: :grace)).postgres?
  end

  test "the token can narrow or widen a specific entitlement" do
    e = Entitlements.new(licensed({"orgs" => 5, "retention_days" => 180}))

    assert_equal 5, e.limit(:orgs)
    assert_equal 180, e.retention_days
    assert_nil e.limit(:accounts), "untouched entitlements keep the licensed default"
  end

  # A signed claim naming something Entitlements does not know must not leak
  # into the table — it would look granted and behave like nothing.
  test "unknown claims in the token are ignored" do
    e = Entitlements.new(licensed({"orgs" => 5, "wildcard" => true}))

    assert_not e.table.key?(:wildcard)
    assert_equal 5, e.limit(:orgs)
  end

  # ── within? — the question every creation point asks ───────────────────

  test "within? counts against the limit" do
    e = Entitlements.new(LicenseToken.new(status: :none))

    assert e.within?(:orgs, 0), "the first org is allowed on the free tier"
    assert_not e.within?(:orgs, 1), "the second is not"
    assert_not e.within?(:member_invites, 0), "a zero limit allows nothing"
  end

  test "a nil limit is never reached" do
    e = Entitlements.new(licensed)

    assert e.within?(:orgs, 10_000)
  end

  # Same posture as Permissions: a typo denies rather than silently granting.
  test "an unknown capability is denied" do
    assert_not Entitlements.new(licensed).within?(:teleportation, 0)
    assert_not Entitlements.new(licensed).enabled?(:teleportation)
  end

  # ── Postgres, which is advertised rather than enforced ─────────────────
  #
  # The control plane already lives in that database by the time this is asked,
  # so refusing to read it would lock the operator out of their own data rather
  # than enforce anything. The product's job is to make the state visible.

  test "Postgres without an entitlement is flagged" do
    assert Entitlements.new(LicenseToken.new(status: :none)).unlicensed_adapter?("postgresql")
  end

  test "Postgres with an entitlement is not flagged" do
    assert_not Entitlements.new(licensed).unlicensed_adapter?("postgresql")
  end

  test "SQLite is never flagged, licensed or not" do
    assert_not Entitlements.new(LicenseToken.new(status: :none)).unlicensed_adapter?("sqlite3")
    assert_not Entitlements.new(licensed).unlicensed_adapter?("sqlite3")
  end
end
