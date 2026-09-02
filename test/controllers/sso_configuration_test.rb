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
class SsoConfigurationTest < ActionDispatch::IntegrationTest
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
    assert_difference("Ops::SsoConfig.count", 1) { turn_on }

    assert_equal "pk_live_abc123", Ops::SsoConfig.current.publishable_key
    assert_equal users(:owner).id, Ops::SsoConfig.current.configured_by_id
  end

  # ── Turning it on moves NOTHING ────────────────────────────────────────
  #
  # This is the property that makes a wrong publishable key survivable. Until a
  # real login proves the credentials work, the workspace is exactly where it
  # was, and CLOWK_ENABLED=0 puts everything back.

  test "the address is recorded as a pending claim, not applied" do
    turn_on

    assert_equal "operator@company.com", Ops::SsoConfig.current.pending_owner_email
    assert Ops::SsoConfig.current.pending_migration?
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

    assert Ops::SsoConfig.current.claimable_by?(named)
    assert_not Ops::SsoConfig.current.claimable_by?(stranger)
  end

  # An unverified address is not identity. A provider that lets someone assert
  # an arbitrary email would otherwise hand over the whole installation.
  test "an unproven address may not claim it" do
    turn_on
    unproven = User.create!(email: "operator@company.com", email_verified: false, clowk_user_id: "s3")

    assert_not Ops::SsoConfig.current.claimable_by?(unproven)
  end

  test "a claim is offered once and not again" do
    turn_on
    claimant = User.create!(email: "operator@company.com", email_verified: true, clowk_user_id: "s4")

    Ops::SsoConfig.current.migrate_to!(claimant)

    assert_not Ops::SsoConfig.current.reload.claimable_by?(claimant)
  end

  # ── The handover itself ────────────────────────────────────────────────

  test "confirming moves the whole workspace onto the real identity" do
    turn_on
    claimant = User.create!(email: "operator@company.com", email_verified: true, clowk_user_id: "s5")

    Ops::SsoConfig.current.migrate_to!(claimant)

    assert_equal 1, claimant.reload.active_orgs.count
    assert_equal 0, @operator.reload.active_orgs.count
    assert_equal claimant.id, @org.reload.account.reload.owner_id, "the account moves too"
  end

  # Turning sign-in off and on again for the same person is the SAME
  # configuration, and it used to be refused. By then that person had a real
  # user row — created by the sign-in the operator had just performed — so
  # re-enabling SSO for themselves was answered with "already has an account
  # here, sign in as them instead", from a screen offering no way to do
  # anything else. A dead end reached by doing exactly what the screen asked.
  test "re-enabling sign-in for an address that already signed in here is accepted" do
    turn_on
    returning = User.create!(email: "operator@company.com", email_verified: true, clowk_user_id: "s9")
    delete ops_sso_path

    assert_difference("Ops::SsoConfig.count", 1) { turn_on }

    assert_match(/sign-in is on/i, flash[:notice])
    assert Ops::SsoConfig.current.claimable_by?(returning), "the claim is still theirs to accept"
  end

  # What the refusal was thought to be protecting is protected elsewhere, and
  # always was: naming an address here records a CLAIM, and the claim is only
  # ever consumed by someone who proves that address and confirms it themselves.
  test "naming an address moves nothing on its own" do
    turn_on(owner_email: users(:contractor).email)

    assert_equal User::LOCAL_OPERATOR_EMAIL, @operator.reload.email
    assert_equal 1, @operator.active_orgs.count, "the workspace has not moved"
    assert_nil Ops::SsoConfig.current.migrated_at
  end

  # No workspace waiting means no handover to promise. Saying otherwise would
  # describe a step that never comes.
  test "the notice does not promise a handover when there is nobody to hand over from" do
    # An installation already running on real identities: the anonymous
    # operator's row is gone as an anonymous operator, which is what
    # adoptable_operator looks for. Renamed rather than destroyed because it
    # still owns the account, and that guard is doing its job.
    @operator.update!(email: "real.person@example.com")

    turn_on

    assert_match(/sign-in is on/i, flash[:notice])
    assert_no_match(/offered this workspace/i, flash[:notice])
    assert_nil Ops::SsoConfig.current.pending_owner_email
  end

  test "an address is required, because the handover needs one" do
    assert_no_difference("Ops::SsoConfig.count") { turn_on(owner_email: "  ") }

    assert_match(/address that will sign in/i, flash[:alert])
  end

  test "a malformed publishable key is refused rather than stored" do
    assert_no_difference("Ops::SsoConfig.count") { turn_on(publishable_key: "not-a-key") }

    assert_match(/pk_live/i, flash[:alert])
  end

  # ── Submitting it has to leave the page ────────────────────────────────
  #
  # Turning sign-in on ends at the Clowk instance: /ops/sso redirects to
  # /clowk/sign_in, which redirects to another ORIGIN. Turbo cannot follow a
  # cross-origin redirect — it does not raise and it does not warn, it drops the
  # fetch. The form then sits there still filled, reading as a button that does
  # nothing, and a later manual refresh works, which reads as flakiness.
  #
  # The string "false" is load-bearing: Phlex omits an attribute whose value is
  # `false`, so `data: {turbo: false}` renders no attribute at all — which is
  # how this was written the first time.
  test "the activation form opts out of Turbo so the browser can follow the redirect" do
    get ops_sso_path

    assert_response :success
    assert_select "form[action=?][data-turbo=?]", ops_sso_path, "false"
  end

  # ── The way out ────────────────────────────────────────────────────────

  test "the environment wins, and the screen says so instead of lying" do
    ENV["CLOWK_ENABLED"] = "0"

    assert_no_difference("Ops::SsoConfig.count") { turn_on }

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

    assert_no_difference("Ops::SsoConfig.count") { turn_on }
  end

  # ── The shape, not the provider ────────────────────────────────────────
  #
  # The table used to carry Clowk's words as columns. Adding a second provider
  # would then have meant either columns null for everyone not using Clowk, or
  # a second table saying the same thing differently.

  test "provider settings live in JSON, reachable as attributes" do
    turn_on

    config = Ops::SsoConfig.current

    assert_equal "clowk", config.provider
    assert_equal "pk_live_abc123", config.publishable_key
    assert_equal({"publishable_key" => "pk_live_abc123"}, config.settings)
  end

  test "an unknown provider is refused" do
    config = Ops::SsoConfig.new(provider: "auth0", publishable_key: "pk_live_x")

    assert_not config.valid?
    assert_includes config.errors.full_messages.join, "Provider"
  end

  # The pk_ shape is Clowk's, so asserting it of every provider would be a bug
  # the day the second one arrives.
  test "the key format check is scoped to the provider that uses it" do
    clowk = Ops::SsoConfig.new(provider: "clowk", publishable_key: "nope")

    assert_not clowk.valid?
    assert_includes clowk.errors.full_messages.join, "pk_live"
  end

  test "the secret is encrypted at rest" do
    turn_on(secret_key: "sk_live_supersecret")

    row = Ops::SsoConfig.connection.select_value(
      "SELECT secret_ciphertext FROM ops_sso_configs ORDER BY created_at DESC LIMIT 1"
    )

    assert_not_nil row
    assert_not_includes row.to_s, "supersecret", "the secret must not sit in the clear"
    assert_equal "sk_live_supersecret", Ops::SsoConfig.current.secret_key
  end

  # `create` has always refused while the environment decides; `destroy` had
  # not. On a host that sets CLOWK_ENABLED the deletion cannot even change
  # sign-in — the env wins on the next resolve — so all it could do is destroy
  # stored configuration for no effect. On a multi-tenant installation that is
  # an unguarded destructive endpoint on installation-wide config.
  test "turning sign-in off is refused while the environment decides" do
    Ops::SsoConfig.create!(provider: "clowk", publishable_key: "pk_live_x")
    ENV["CLOWK_ENABLED"] = "1"
    ENV["CLOWK_PUBLISHABLE_KEY"] = "pk_live_env"

    delete ops_sso_path

    assert_equal 1, Ops::SsoConfig.count, "the stored config was deleted anyway"
    assert_match(/environment variables/, flash[:alert])
  ensure
    ENV.delete("CLOWK_ENABLED")
    ENV.delete("CLOWK_PUBLISHABLE_KEY")
  end

  # ── The switch actually throws ─────────────────────────────────────────
  #
  # Everything above proves the ROW is written and read. None of it proved that
  # sign-in itself changes, and it did not: config/initializers/clowk.rb pinned
  # the environment's answer into config.x.clowk_enabled even when the
  # environment had given none, and clowk_enabled? returned that pin without
  # consulting anything else. The stored row was therefore inert on every
  # installation — the screen reported success, the badge kept saying `none`,
  # and every request went on running as the anonymous operator.
  #
  # These run UNPINNED, which is the shape of a real deployment: no environment
  # file sets the flag in development or production. The test env pins `true` so
  # the rest of the suite keeps exercising the multi-tenant path, and that pin
  # is exactly what hid this.

  def unpinned
    previous = Rails.application.config.x.clowk_enabled
    Rails.application.config.x.clowk_enabled = nil
    yield
  ensure
    Rails.application.config.x.clowk_enabled = previous
  end

  test "the stored row turns sign-in on when the environment is silent" do
    unpinned do
      assert_not AuthSettings.effective.enabled?, "an install with no row is anonymous"

      turn_on

      assert AuthSettings.effective.enabled?, "the screen must take effect without a redeploy"
      assert_equal "pk_live_abc123", AuthSettings.effective.publishable_key
    end
  end

  test "deleting the stored row turns sign-in back off" do
    unpinned do
      turn_on

      assert AuthSettings.effective.enabled?

      delete ops_sso_path

      assert_not AuthSettings.effective.enabled?, "turning it off must take effect too"
    end
  end

  # The safety valve. A wrong key saved here would otherwise be unrecoverable
  # without database surgery, so the environment has to keep overriding the row
  # in BOTH directions.
  test "the environment still overrides the stored row" do
    unpinned do
      turn_on

      ENV["CLOWK_ENABLED"] = "0"

      assert_not AuthSettings.effective.enabled?, "CLOWK_ENABLED=0 is the way back"
    end
  ensure
    ENV.delete("CLOWK_ENABLED")
  end

  # config.x.clowk_enabled is still the seam an environment file and the suite
  # use, and it still wins — it just no longer speaks for an environment that
  # said nothing.
  test "a pinned flag beats the stored row" do
    turn_on

    Rails.application.config.x.clowk_enabled = false

    assert_not AuthSettings.effective.enabled?
    assert AuthSettings.current.enabled?, "the row is still what is configured"
  ensure
    Rails.application.config.x.clowk_enabled = true
  end

  # An undecided flag is an empty ActiveSupport::OrderedOptions, which is
  # truthy. Anything reading it with a bare truth test therefore reads
  # "undecided" as "on" — which is how the production boot guard would come to
  # raise on every fresh self-hosted box.
  test "undecided is not mistaken for decided" do
    unpinned do
      assert_nil AuthSettings.pinned_flag
      assert_not_equal true, Rails.application.config.x.clowk_enabled
    end
  end

  # ── …and the requests themselves change ────────────────────────────────
  #
  # The two above prove the resolver. These prove the guard that uses it, which
  # is where the bug actually bit: clowk_enabled? read the pin and returned, so
  # require_authentication! kept letting everyone through no matter what the
  # screen said.

  test "a signed-out request is sent to sign-in once the screen turned it on" do
    unpinned do
      turn_on
      sign_out

      get ops_license_path

      assert_response :redirect
      assert_not_equal ops_license_url, response.location, "it must be the door, not the page"
    end
  end

  # The reason the credentials are put in force by middleware and not by an
  # around_action. Clowk::BaseController inherits from ActionController::Base,
  # not from ours, so the engine's own controllers never run our filters — and
  # those are /sign_in and the OAuth callback that VERIFIES THE TOKEN. A filter
  # would have covered every page except the two that decide whether anybody is
  # signed in, and every test that pins credentials in the environment would
  # still have passed.
  #
  # The gem resolves the auth domain from the publishable key, over the network,
  # so the resolution cache is primed instead — and that sharpens the assertion
  # rather than weakening it: the cache is keyed by publishable key, so a hit
  # can only happen if the STORED key was the one in force. Unscoped, the boot
  # configuration would have sent this to acme.clowk.dev.
  test "the engine's own controllers get the stored credentials" do
    unpinned do
      Ops::SsoConfig.create!(provider: "clowk", publishable_key: "pk_live_tenant")
      Clowk::Subdomain.write_cache("instance-url:pk_live_tenant", "https://tenant.clowk.dev", ttl: 60)
      sign_out

      get "/sign_in"

      assert_response :redirect
      assert response.location.start_with?("https://tenant.clowk.dev"),
        "the engine resolved against #{response.location.inspect}, not the stored instance"
    end
  ensure
    Clowk::Subdomain.clear_cache!
  end

  # The development door exists because a developer with no publishable key
  # would otherwise meet a 500 on their first page. It decided that by reading
  # Clowk.config, which is empty on an installation configured from the SSO
  # screen — the key lives in the row and is scoped per request. So configuring
  # a real instance in development sent you to the local pretend door, with no
  # way past it: the one address the screen asked you to use was not on the
  # list, and signing in as anything else was not the flow under test.
  test "a configured instance is not sent to the development door" do
    unpinned do
      Ops::SsoConfig.create!(provider: "clowk", publishable_key: "pk_live_tenant")
      Clowk::Subdomain.write_cache("instance-url:pk_live_tenant", "https://tenant.clowk.dev", ttl: 60)
      sign_out

      Rails.stub(:env, ActiveSupport::StringInquirer.new("development")) do
        get ops_license_path
      end

      assert_response :redirect
      assert_no_match(%r{/dev/sign_in}, response.location,
        "a real instance is configured — the development door must not answer")
    end
  ensure
    Clowk::Subdomain.clear_cache!
  end

  test "a signed-out request is served anonymously once the screen turned it off" do
    unpinned do
      turn_on
      delete ops_sso_path
      sign_out

      get ops_license_path

      assert_response :success
      assert_includes response.body, User::LOCAL_OPERATOR_EMAIL, "back to the local operator"
    end
  end
end
