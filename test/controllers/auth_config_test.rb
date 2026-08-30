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
    post auth_config_path, params: {
      publishable_key: "pk_live_abc123", owner_email: "operator@company.com"
    }.merge(params)
  end

  test "turning on sign-in stores the credentials" do
    assert_difference("AuthConfig.count", 1) { turn_on }

    assert_equal "pk_live_abc123", AuthConfig.current.publishable_key
    assert_equal users(:owner).id, AuthConfig.current.configured_by_id
  end

  # ── The handover ───────────────────────────────────────────────────────

  test "the local operator is renamed to the address that will sign in" do
    turn_on

    assert_equal "operator@company.com", @operator.reload.email
    assert_not @operator.email_verified, "unproven until they actually sign in"
  end

  test "the workspace survives the handover" do
    servers_before = @org.servers.count
    turn_on

    assert_equal 1, @operator.reload.active_orgs.count, "the org must still be theirs"
    assert_equal servers_before, @org.reload.servers.count
  end

  # The mechanism, end to end: the first Clowk sign-in with that address adopts
  # the operator row instead of creating a stranger.
  test "the first Clowk sign-in inherits the workspace rather than starting over" do
    turn_on

    adopted = User.provision_from_clowk!(
      sub: "clowk-sub-1", email: "operator@company.com", name: "Operator",
      email_verified: true, provider: "google"
    )

    assert_equal @operator.id, adopted.id, "a new row here means the workspace was stranded"
    assert_equal 1, adopted.active_orgs.count
    assert_equal "clowk-sub-1", adopted.clowk_user_id
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

    delete auth_config_path

    assert_not AuthSettings.current.enabled?
    assert_match(/anonymous again/i, flash[:notice])
  end

  test "only an owner may change how the installation authenticates" do
    sign_out
    sign_in_as(email: users(:contractor).email)

    assert_no_difference("AuthConfig.count") { turn_on }
  end
end
