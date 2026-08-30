# frozen_string_literal: true

require "test_helper"

# Buying Clowk after the fact: an anonymous install turns on real sign-in from
# Settings, without a redeploy.
#
# The test that matters most is the handover. Anonymous mode runs as one local
# operator row; a Clowk sign-in provisions by subject. Without renaming that row
# to the address that will sign in, the first real login creates a NEW user with
# no membership, lands on onboarding, and leaves every server and PAT in an org
# nobody can reach. That is silent, total, and only visible after the operator
# has already switched.
class AuthConfigTest < ActionDispatch::IntegrationTest
  setup do
    sign_out
    sign_in_as(email: users(:owner).email)

    @env = {}
    %w[CLOWK_ENABLED CLOWK_PUBLISHABLE_KEY CLOWK_SUBDOMAIN_URL].each { |k| @env[k] = ENV.delete(k) }

    # The local operator, as an install that has been running anonymously has.
    @operator = User.create!(email: User::LOCAL_OPERATOR_EMAIL, name: "Local operator",
      email_verified: false)
    @org = Account.provision!(owner: @operator, account_name: "Local", org_name: "Default")
  end

  teardown { @env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v } }

  def turn_on(params = {})
    post ops_sso_path, params: {
      publishable_key: "pk_live_abc123", owner_email: "operator@company.com"
    }.merge(params)
  end

  test "turning on sign-in stores the credentials" do
    assert_difference("AuthConfig.count", 1) { turn_on }

    assert_equal "pk_live_abc123", AuthConfig.current.publishable_key
    assert_equal users(:owner).id, AuthConfig.current.configured_by_id
  end

  # ── Turning it on moves NOTHING ────────────────────────────────────────
  #
  # This is the property that makes a wrong publishable key survivable. Until a
  # real login proves the credentials work, the workspace is exactly where it
  # was, and CLOWK_ENABLED=0 puts everything back.

  test "the address is recorded as a pending claim, not applied" do
    turn_on

    assert_equal "operator@company.com", AuthConfig.current.pending_owner_email
    assert AuthConfig.current.pending_migration?
  end

  test "the local operator is untouched until someone confirms" do
    turn_on

    assert_equal User::LOCAL_OPERATOR_EMAIL, @operator.reload.email
    assert_equal 1, @operator.active_orgs.count, "the workspace has not moved"
  end

  # ── Who may claim it ───────────────────────────────────────────────────

  test "only the named address may claim the workspace" do
    turn_on
    named = User.create!(email: "operator@company.com", email_verified: true, clowk_user_id: "s1")
    stranger = User.create!(email: "someone@else.com", email_verified: true, clowk_user_id: "s2")

    assert AuthConfig.current.claimable_by?(named)
    assert_not AuthConfig.current.claimable_by?(stranger)
  end

  # An unverified address is not identity. A provider that lets someone assert
  # an arbitrary email would otherwise hand over the whole installation.
  test "an unproven address may not claim it" do
    turn_on
    unproven = User.create!(email: "operator@company.com", email_verified: false, clowk_user_id: "s3")

    assert_not AuthConfig.current.claimable_by?(unproven)
  end

  test "a claim is offered once and not again" do
    turn_on
    claimant = User.create!(email: "operator@company.com", email_verified: true, clowk_user_id: "s4")

    AuthConfig.current.migrate_to!(claimant)

    assert_not AuthConfig.current.reload.claimable_by?(claimant)
  end

  # ── The handover itself ────────────────────────────────────────────────

  test "confirming moves the whole workspace onto the real identity" do
    turn_on
    claimant = User.create!(email: "operator@company.com", email_verified: true, clowk_user_id: "s5")

    AuthConfig.current.migrate_to!(claimant)

    assert_equal 1, claimant.reload.active_orgs.count
    assert_equal 0, @operator.reload.active_orgs.count
    assert_equal claimant.id, @org.reload.account.reload.owner_id, "the account moves too"
  end

  test "an address that already belongs to someone else is refused" do
    assert_no_difference("AuthConfig.count") { turn_on(owner_email: users(:contractor).email) }

    assert_match(/already has an account/i, flash[:alert])
  end

  test "an address is required, because the handover needs one" do
    assert_no_difference("AuthConfig.count") { turn_on(owner_email: "  ") }

    assert_match(/address that will sign in/i, flash[:alert])
  end

  test "a malformed publishable key is refused rather than stored" do
    assert_no_difference("AuthConfig.count") { turn_on(publishable_key: "not-a-key") }

    assert_match(/pk_live/i, flash[:alert])
  end

  # ── The way out ────────────────────────────────────────────────────────

  test "the environment wins, and the screen says so instead of lying" do
    ENV["CLOWK_ENABLED"] = "0"

    assert_no_difference("AuthConfig.count") { turn_on }

    assert_match(/environment variables/i, flash[:alert])
    assert_not AuthSettings.current.enabled?, "the env must still decide"
  end

  test "sign-in can be turned back off from the screen" do
    turn_on

    assert AuthSettings.current.enabled?

    delete ops_sso_path

    assert_not AuthSettings.current.enabled?
    assert_match(/anonymous again/i, flash[:notice])
  end

  test "only an owner may change how the installation authenticates" do
    sign_out
    sign_in_as(email: users(:contractor).email)

    assert_no_difference("AuthConfig.count") { turn_on }
  end
end
