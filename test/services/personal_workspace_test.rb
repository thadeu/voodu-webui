# frozen_string_literal: true

require "test_helper"

# Everybody on the hosted service owns a workspace, from the moment they arrive.
#
# Being invited into somebody else's org used to be the END of the road: it gave
# you a membership, and a membership answered "do you belong to an org?", which
# was the question guarding onboarding. So a consultant invited into one
# customer's org could never have a workspace of their own — not because
# anybody decided that, but because two different questions shared one answer.
#
# On the hosted service the workspace is not something to ask for. It is
# created on arrival, so an invitation ADDS to what somebody has instead of
# replacing it, and losing the invitation later leaves them with what was
# already theirs.
class PersonalWorkspaceTest < ActiveSupport::TestCase
  HOSTED = LicenseToken.new(
    status: :valid,
    claims: {"sub" => "hosted", "exp" => 1.year.from_now.to_i, "tier" => "unlimited"}
  )
  ENTERPRISE = LicenseToken.new(
    status: :valid, claims: {"sub" => "acme", "exp" => 1.year.from_now.to_i}
  )
  OSS = LicenseToken.new(status: :none)

  def arriving = User.create!(email: "arriving-#{SecureRandom.hex(4)}@example.com", email_verified: true)

  # ── The hosted service ────────────────────────────────────────────

  test "somebody arriving on the hosted service owns a workspace" do
    user = arriving

    assert_difference ["Account.count", "Org.count"], 1 do
      PersonalWorkspace.ensure_for(user, license: HOSTED)
    end

    assert user.reload.owned_accounts.one?
    assert user.active_orgs.one?, "and an org they can actually reach"
  end

  test "the workspace makes them its owner, not merely a member" do
    user = arriving
    PersonalWorkspace.ensure_for(user, license: HOSTED)

    assert_equal "owner", user.reload.org_memberships.active.sole.role
  end

  test "arriving twice does not produce two workspaces" do
    user = arriving
    PersonalWorkspace.ensure_for(user, license: HOSTED)

    assert_no_difference "Account.count" do
      3.times { PersonalWorkspace.ensure_for(user, license: HOSTED) }
    end
  end

  # The scenario this exists for: an invitation adds, it does not replace.
  test "somebody invited elsewhere still gets their own" do
    host = arriving
    PersonalWorkspace.ensure_for(host, license: HOSTED)
    host_org = host.owned_accounts.sole.orgs.sole

    guest = arriving
    host_org.memberships.create!(user: guest, role: :admin, status: :active,
      invited_at: Time.current, invited_by: host)

    PersonalWorkspace.ensure_for(guest, license: HOSTED)

    assert guest.reload.owned_accounts.one?, "the invitation should not stand in for a workspace"
    assert_equal 2, guest.active_orgs.count, "their own, plus the one they were invited into"
  end

  # And what they own survives losing what they were lent.
  test "losing the invitation leaves their own workspace behind" do
    host = arriving
    PersonalWorkspace.ensure_for(host, license: HOSTED)
    host_org = host.owned_accounts.sole.orgs.sole

    guest = arriving
    membership = host_org.memberships.create!(user: guest, role: :admin, status: :active,
      invited_at: Time.current, invited_by: host)
    PersonalWorkspace.ensure_for(guest, license: HOSTED)

    membership.destroy!

    assert_equal 1, guest.reload.active_orgs.count
    assert guest.owned_accounts.one?
  end

  # ── Self-hosted must NOT get this ─────────────────────────────────
  #
  # Both self-hosted tiers hold ONE account. Auto-provisioning there would hand
  # a workspace to the first stranger who could authenticate, and would consume
  # the single account the operator was entitled to — the opposite of what the
  # cap is for.

  test "an Enterprise installation provisions nothing automatically" do
    user = arriving

    assert_no_difference ["Account.count", "Org.count"] do
      PersonalWorkspace.ensure_for(user, license: ENTERPRISE)
    end

    assert_empty user.reload.owned_accounts
  end

  test "an OSS installation provisions nothing automatically" do
    user = arriving

    assert_no_difference ["Account.count", "Org.count"] do
      PersonalWorkspace.ensure_for(user, license: OSS)
    end

    assert_empty user.reload.owned_accounts
  end

  # Even with room to spare — the rule is the TIER, not the count. A fresh
  # self-hosted box has room, and the first person there must still choose
  # their own names rather than have a workspace appear around them.
  test "a self-hosted box with room still provisions nothing" do
    Server.delete_all
    Org::Membership.delete_all
    Org.delete_all
    Account.delete_all

    user = arriving

    assert_no_difference "Account.count" do
      PersonalWorkspace.ensure_for(user, license: ENTERPRISE)
    end
  end

  # The local operator in anonymous mode already has a workspace of its own,
  # made when it was provisioned. Nothing here should add a second.
  test "the anonymous operator is left alone" do
    operator = User.local_operator

    assert_no_difference "Account.count" do
      PersonalWorkspace.ensure_for(operator, license: OSS)
    end
  end
end
