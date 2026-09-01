# frozen_string_literal: true

require "test_helper"

# The workspace appears on arrival, over HTTP.
#
# The unit tests cover the rule. This covers the thing only a request shows:
# that somebody invited into another company's org still arrives at a workspace
# of their own, and never meets the onboarding form to ask for one — and that a
# self-hosted box hands out nothing to anybody who walks up.
class PersonalWorkspaceAtTheDoorTest < ActionDispatch::IntegrationTest
  HOSTED = LicenseToken.new(
    status: :valid,
    claims: {"sub" => "hosted", "exp" => 1.year.from_now.to_i, "tier" => "unlimited"}
  )
  ENTERPRISE = LicenseToken.new(
    status: :valid, claims: {"sub" => "cliente", "exp" => 1.year.from_now.to_i}
  )
  OSS = LicenseToken.new(status: :none)

  # Restored, not merely set. Every one of these swaps the installation's
  # licence, and the suite's own default is the thing left behind — the next
  # test to read it as "how this box is licensed" would silently be measuring
  # the hosted tier.
  setup do
    @installed = Rails.application.config.x.license
    Current.reset
  end

  teardown { Rails.application.config.x.license = @installed }

  def hosted! = Rails.application.config.x.license = HOSTED

  # Only the cookie — not sign_in_as, which provisions the row itself and would
  # do the work under test. A browser arrives holding a token and nothing else.
  def arrive_as(email, sub: "clowk-#{SecureRandom.hex(4)}")
    cookies[Clowk.config.cookie_key] = ClowkDevToken.mint(
      sub: sub, email: email, name: "X", email_verified: true
    )
  end

  def invitation_for(email)
    invited = User.create!(email: email)
    orgs(:acme).memberships.create!(user: invited, role: :admin, status: :invited,
      invited_at: Time.current, invited_by: users(:owner))
    invited
  end

  # ── Hosted ────────────────────────────────────────────────────────

  test "somebody holding an invitation arrives owning a workspace as well" do
    hosted!
    mario = invitation_for("mario@x.com")

    arrive_as("mario@x.com")
    get root_path(org_id: nil, server_key: nil)

    assert mario.reload.owned_accounts.one?, "the invitation should not stand in for a workspace"
    assert mario.active_orgs.one?, "his own, before he has accepted anything"
  end

  # The whole scenario, end to end: accepting ADDS the other company's org to
  # what he already owns, rather than being the only thing he has.
  test "and after accepting the invitation he holds both" do
    hosted!
    mario = invitation_for("mario@x.com")
    arrive_as("mario@x.com")
    get root_path(org_id: nil, server_key: nil)

    get invite_path(mario.org_memberships.where(org: orgs(:acme)).sole.invite_token)

    assert_equal 2, mario.reload.active_orgs.count, "his own, and the one he was invited into"
    assert_equal ["owner", "admin"].sort, mario.org_memberships.active.map(&:role).sort
  end

  # And what he owns outlives what he was lent.
  test "losing the invitation leaves his own workspace behind" do
    hosted!
    mario = invitation_for("mario@x.com")
    arrive_as("mario@x.com")
    get root_path(org_id: nil, server_key: nil)

    mario.org_memberships.where(org: orgs(:acme)).destroy_all

    assert mario.reload.owned_accounts.one?
    assert mario.active_orgs.one?
  end

  test "and is never asked to fill in the onboarding form" do
    hosted!
    invitation_for("mario@x.com")
    arrive_as("mario@x.com")

    get new_onboarding_path

    assert_response :redirect
  end

  # The backfill: somebody who accepted an invitation long before any of this
  # existed gets their workspace on their next sign-in, with nothing to do.
  test "an existing member with no workspace is given one on the next request" do
    hosted!
    member = users(:contractor)
    member.owned_accounts.destroy_all

    assert_empty member.reload.owned_accounts

    arrive_as(member.email, sub: member.clowk_user_id.presence || "clowk-backfill")
    get root_path(org_id: nil, server_key: nil)

    assert member.reload.owned_accounts.one?
  end

  # ── Self-hosted gets none of it ───────────────────────────────────
  #
  # Both self-hosted tiers hold ONE account. Auto-provisioning would spend it
  # on whoever authenticated first.

  test "an Enterprise box provisions no workspace for an invited admin" do
    Rails.application.config.x.license = ENTERPRISE
    mario = invitation_for("mario@x.com")

    assert_no_difference ["Account.count", "Org.count"] do
      arrive_as("mario@x.com")
      get root_path(org_id: nil, server_key: nil)
    end

    assert_empty mario.reload.owned_accounts
  end

  test "an OSS box provisions no workspace either" do
    Rails.application.config.x.license = OSS
    mario = invitation_for("mario@x.com")

    assert_no_difference ["Account.count", "Org.count"] do
      arrive_as("mario@x.com")
      get root_path(org_id: nil, server_key: nil)
    end

    assert_empty mario.reload.owned_accounts
  end

  # On the hosted service there is no such thing as a stranger: arrival IS
  # signing up, and what a new signup gets is the free tier. Pinned because it
  # reads like a hole and is not one — the account cap is what closes the door,
  # and the hosted tier deliberately has none.
  test "an unknown address on the hosted service is a signup, and gets the free tier" do
    hosted!

    assert_difference ["User.count", "Account.count"], 1 do
      arrive_as("newcomer@internet.example")
      get root_path(org_id: nil, server_key: nil)
    end

    assert_equal "free", User.find_by(email: "newcomer@internet.example").owned_accounts.sole.plan
  end

  # Self-hosted is where a stranger exists, and the refusal comes first: no row,
  # and so no workspace on the way out.
  test "on a self-hosted box a stranger is refused and gets nothing" do
    Rails.application.config.x.license = ENTERPRISE

    assert_no_difference ["User.count", "Account.count"] do
      arrive_as("nobody@internet.example")
      get root_path(org_id: nil, server_key: nil)
    end

    assert_response :forbidden
  end
end
