# frozen_string_literal: true

require "test_helper"

# What an admin invited into somebody else's org may and may not do.
#
# This is the shape the hosted service creates and self-hosted rarely did: a
# person who owns their OWN account and is also an admin inside another
# company's. Two accounts are in play on every request they make, and each
# screen has to be clear about which one it is acting on. Where it was not,
# the answer it picked was the wrong one — the company that invited them.
class InvitedAdminBoundariesTest < ActionDispatch::IntegrationTest
  HOSTED = LicenseToken.new(
    status: :valid,
    claims: {"sub" => "hosted", "exp" => 1.year.from_now.to_i, "tier" => "unlimited"}
  )

  setup do
    @installed = Rails.application.config.x.license
    Rails.application.config.x.license = HOSTED

    # Their own account, as PersonalWorkspace would have made it on arrival.
    @guest = users(:contractor)
    @guest.owned_accounts.destroy_all
    PersonalWorkspace.ensure_for(@guest, license: HOSTED)
    @own = @guest.reload.owned_accounts.sole

    # And admin inside acme, which belongs to somebody else.
    orgs(:acme).memberships.find_by(user: @guest)&.update!(role: :admin, status: :active)

    sign_in_as(email: @guest.email)
  end

  teardown { Rails.application.config.x.license = @installed }

  # ── Inviting is the owner's, not the admin's ──────────────────────
  #
  # An admin who can invite can invite another admin, and an admin can reveal
  # every PAT in the org — so the seat the owner is paying for lets somebody
  # else hand out the infrastructure. Running the org day to day is admin's;
  # deciding who is in it is not.

  # Bounced, not 403 — `authorize` redirects with an explanation, which is the
  # house convention for a capability an operator simply does not hold.
  test "an admin cannot reach the members screen of an org they do not own" do
    get org_members_path(org_id: orgs(:acme).short_id)

    assert_response :redirect
    assert_match(/owner/i, flash[:alert].to_s)
  end

  test "and cannot post an invitation to it" do
    assert_no_difference "Org::Membership.count" do
      post org_members_path(org_id: orgs(:acme).short_id),
        params: {email: "someone-else@example.com", role: "admin"}
    end

    assert_response :redirect
  end

  test "the owner of that org still can" do
    sign_out
    sign_in_as(email: users(:owner).email)

    get org_members_path(org_id: orgs(:acme).short_id)

    assert_response :success
  end

  # ── The plan is the account they own ──────────────────────────────

  test "the licence screen names the account whose plan it is showing" do
    get "/ops/license"

    assert_response :success
    assert_includes response.body, "Your plan · #{@own.name}"
  end

  # With an org in the query string, which is the only way one gets into scope
  # on this route. current_account follows it; plan_account does not — and
  # under current_account this page titled "Your plan" showed the plan of the
  # company that invited them, with the activation form beside it.
  test "and shows theirs even with the host org forced into scope" do
    other = orgs(:acme).account
    other.update!(name: "Acme Holdings")

    get "/ops/license?org_id=#{orgs(:acme).short_id}"

    assert_response :success
    assert_includes response.body, "Your plan · #{@own.name}"

    # Scoped to the card's own title, not the whole page: the org switcher now
    # labels every org with its account on purpose, so "Acme Holdings" appears
    # elsewhere on this page and asserting on the body would be asserting
    # against a different feature.
    assert_not_includes response.body, "Your plan · Acme Holdings"
  end

  # And the form is the owner's alone: rendering it for a visitor would offer
  # to write a plan licence onto an account that is not theirs.
  test "no activation form is offered for an account they do not own" do
    get "/ops/license?org_id=#{orgs(:acme).short_id}"

    assert_select "textarea#plan-token", 1

    # The form states which account a licence must be issued for, and that
    # sentence is the one place the write target is named to the operator.
    assert_includes response.body, "Issued for this account (#{@own.short_id})"
    assert_not_includes response.body, "Issued for this account (#{orgs(:acme).account.short_id})"
  end

  # The form writes to the account it names. Before plan_account existed this
  # read the visited org's, so an admin could put a plan on somebody else's
  # account — or, on the bare /ops/license, on nothing at all.
  test "activating a plan lands on their own account" do
    token = plan_token_for(@own)

    post ops_license_path, params: {scope: "plan", license_token: token}

    assert_equal "pro", @own.reload.plan
    assert_equal "free", orgs(:acme).account.reload.plan
  end

  # ── Orgs land in the account they own ─────────────────────────────

  test "a new org goes into their own account, not the one they administer" do
    # Pro first: their personal account is on free, which allows one org and
    # they already have it — otherwise this measures the entitlement cap
    # instead of where the org lands.
    @own.activate_plan!(plan_token_for(@own))

    post orgs_path, params: {org: {name: "Guest Project"}}, as: :turbo_stream

    created = Org.find_by(name: "Guest Project")

    assert created, "org was not created: #{response.status} #{flash.to_h.inspect}"
    assert_equal @own.id, created.account_id
  end

  private

  def plan_token_for(account)
    key = OpenSSL::PKey::RSA.new(Rails.root.join("config/license/private_key.pem").read)

    JWT.encode({
      "sub" => account.short_id, "iat" => Time.current.to_i,
      "exp" => 1.year.from_now.to_i, "tier" => "unlimited", "plan" => "pro", "ent" => {}
    }, key, "RS256")
  end
end
