# frozen_string_literal: true

require "test_helper"

# What a hosted customer is not shown, and not allowed to reach.
#
# On the hosted service the installation belongs to whoever operates it. Two
# things follow, and both are about the same confusion: a tenant seeing
# installation-wide controls assumes they govern their own account.
#
#   SSO      decided once, for every tenant at the same time. A form offering
#            to change it offers something it cannot do, and `destroy` would be
#            one customer turning sign-in off for everybody.
#   Licence  the badge reports OUR licence's health in two words, Free and
#            Licensed, neither of which describes anything they bought.
#
# What they DID buy is the plan on their account, so /ops/license stays — that
# screen is where a plan licence gets activated.
class HostedInstallationChromeTest < ActionDispatch::IntegrationTest
  HOSTED = LicenseToken.new(
    status: :valid,
    claims: {"sub" => "hosted", "exp" => 1.year.from_now.to_i, "tier" => "unlimited"}
  )

  setup do
    @installed = Rails.application.config.x.license
    sign_in_as(email: users(:owner).email)
  end

  teardown { Rails.application.config.x.license = @installed }

  def hosted! = Rails.application.config.x.license = HOSTED

  def a_page
    get server_root_path(org_id: "acmeorg1", server_key: servers(:alpha).key)

    assert_response :success
  end

  # The bare paths, as the sidebar builds them. test_helper pins a global
  # org_id default, so `ops_sso_path` alone yields "/ops/sso?org_id=acmeorg1" —
  # a selector that matches nothing on any page, in either direction. Both
  # count: 0 assertions below passed vacuously until the self-hosted
  # counterparts caught it.
  SSO_HREF = "/ops/sso"
  LICENSE_HREF = "/ops/license"

  # Requested as a browser requests it: bare, with no :org_id. test_helper pins
  # a global org_id default, so `get ops_license_path` silently asks for
  # "/ops/license?org_id=acmeorg1" — which resolves current_org and hides the
  # very bug these tests exist for. Reverting the fix passed happily until this
  # was fixed too.
  def visit_license = get LICENSE_HREF

  # ── Hosted ────────────────────────────────────────────────────────

  test "the SSO screen redirects away instead of rendering" do
    hosted!

    get ops_sso_path

    assert_redirected_to root_path(org_id: nil, server_key: nil)
  end

  # Hiding a screen whose POST still answers is not hiding it. This is the
  # assertion that would have caught a guard written as `before_action ...,
  # only: :index`.
  test "and so do its writes, not only the screen" do
    hosted!

    assert_no_difference "Ops::SsoConfig.count" do
      post ops_sso_path, params: {
        publishable_key: "pk_test_intruder", owner_email: "someone@example.com"
      }
    end

    assert_redirected_to root_path(org_id: nil, server_key: nil)
  end

  test "and the delete, which would turn sign-in off for every tenant" do
    hosted!
    Ops::SsoConfig.create!(provider: :clowk, publishable_key: "pk_test_existing")

    assert_no_difference "Ops::SsoConfig.count" do
      delete ops_sso_path
    end

    assert_redirected_to root_path(org_id: nil, server_key: nil)
  end

  test "the sidebar does not advertise the door that redirects" do
    hosted!

    a_page

    assert_select "a[href=?]", SSO_HREF, count: 0
  end

  test "the installation licence badge is gone from the topbar" do
    hosted!

    a_page

    assert_select "header span[title*=?]", "Licensed to", count: 0
  end

  # The half that must survive: a hosted customer buys a plan, and this is
  # where they activate it.
  test "the licence screen stays, because the plan lives there" do
    hosted!

    visit_license

    assert_response :success
    a_page
    assert_select "a[href=?]", LICENSE_HREF, minimum: 1
  end

  # ── Self-hosted keeps all of it ───────────────────────────────────

  test "a self-hosted box still reaches its SSO screen" do
    get ops_sso_path

    assert_response :success
  end

  test "and still sees both doors and the badge" do
    a_page

    assert_select "a[href=?]", SSO_HREF, minimum: 1
    assert_select "a[href=?]", LICENSE_HREF, minimum: 1
    assert_select "header span[title*=?]", "Licensed to", minimum: 1
  end

  # ── The plan card, which was invisible ────────────────────────────
  #
  # /ops/license takes no :org_id by design, so `current_org` is nil on every
  # visit — and the card that shows a hosted customer their plan, along with
  # the ONLY form that can upgrade it, was gated on `current_org&.account`. It
  # returned early every time. The effect was a dead end with no error in it: a
  # free account saw "0 invites", and nothing on any screen offered a way to
  # buy more. The controller could activate a plan licence the whole time.

  test "a hosted customer sees their plan without an org in the URL" do
    hosted!

    visit_license

    assert_response :success
    assert_includes response.body, "Your plan"
  end

  test "and is given the form that upgrades it" do
    hosted!

    visit_license

    assert_select "textarea#plan-token", 1
    assert_select "input[name=?][value=?]", "scope", "plan"
  end

  # The form has to name the account it binds to, because a plan licence issued
  # for another one is refused — and the customer needs the short_id to ask for
  # the right token in the first place.
  test "the form names the account the licence must be issued for" do
    hosted!

    visit_license

    assert_includes response.body, users(:owner).owned_accounts.first.short_id
  end

  # Self-hosted has no plan card at all: the box's licence already says what
  # they have, and a second answer could only disagree with it.
  test "a self-hosted box is offered no plan form" do
    visit_license

    assert_select "textarea#plan-token", false
    assert_select "textarea#license-token", 1
  end
end
