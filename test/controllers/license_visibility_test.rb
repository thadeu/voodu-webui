# frozen_string_literal: true

require "test_helper"

# The plan has to be visible, including on the free tier.
#
# An operator who cannot see which plan they are on opens a ticket to ask, and
# an operator whose licence lapsed silently opens a angrier one. This is the
# only screen that can explain why a capability they paid for stopped applying,
# so "it renders" is the actual requirement, not a detail.
class LicenseVisibilityTest < ActionDispatch::IntegrationTest
  setup do
    sign_out
    sign_in_as(email: users(:owner).email)
    @previous = Rails.application.config.x.license
  end

  teardown { Rails.application.config.x.license = @previous }

  # The licence has its own screen, named for what it is — not a card inside a
  # server's settings.
  def settings
    get ops_license_path
  end

  def stub_license(status, customer: "acme-corp", expires: 30.days.from_now)
    Rails.application.config.x.license = LicenseToken.new(
      status: status, claims: {"sub" => customer, "exp" => expires.to_i}
    )
  end

  test "the free tier says so" do
    Rails.application.config.x.license = LicenseToken.new(status: :none)

    settings

    assert_response :success
    assert_includes response.body, "Free"
  end

  test "a live licence names the customer and the date" do
    stub_license(:valid, expires: Date.new(2027, 6, 1).to_time)

    settings

    assert_response :success
    assert_includes response.body, "Enterprise"
    assert_includes response.body, "acme-corp"
    assert_includes response.body, "2027-06-01"
  end

  # The two states an operator most needs to see, and would otherwise learn
  # about through a capability quietly disappearing.
  test "grace is called out, not hidden" do
    stub_license(:grace, expires: 2.days.ago)

    settings

    assert_includes response.body, "in grace"
  end

  test "a lapsed licence says whose, so it can be renewed" do
    stub_license(:lapsed, expires: 60.days.ago)

    settings

    assert_includes response.body, "lapsed"
    assert_includes response.body, "acme-corp"
  end

  test "an unverifiable licence admits it rather than showing Enterprise" do
    Rails.application.config.x.license = LicenseToken.new(status: :invalid, reason: "VerificationError")

    settings

    assert_includes response.body, "could not be verified"
    assert_not_includes response.body, "Enterprise ·"
  end

  # Why this screen is not inside /:org_id/:server_key/settings.
  #
  # The licence and the sign-in method configure the container, so an operator
  # who has not registered a server yet — which is everyone on their first day —
  # must still be able to reach them. Hanging them off a server meant buying a
  # licence required already having somewhere to put it.
  test "reachable with no server registered at all" do
    Server.delete_all

    get ops_license_path

    assert_response :success
    assert_includes response.body, "License"
    assert_includes response.body, "Plan"
  end

  # ── Env-pinned: the host decided ──────────────────────────────────
  #
  # The rule sign-in already follows, applied to the licence: configuration the
  # HOST set wins, so the screen shows it and does not offer an edit the next
  # boot would silently undo. This is what makes the hosted service safe to
  # leave these screens visible on — every tenant can read them, none can write.

  def env_pinned(tier: "enterprise")
    Rails.application.config.x.license = LicenseToken.new(
      status: :valid,
      claims: {"sub" => "voodu-hosted", "exp" => 30.days.from_now.to_i, "tier" => tier},
      source: :env
    )
  end

  # The renewal flow, which is why the environment does NOT lock the form: an
  # operator's env-supplied licence expires, they buy another, and the only
  # place to put it is this form. Locking it would remove the form at exactly
  # the moment it was needed.
  test "an env-supplied licence still offers the form, so a renewal can land" do
    env_pinned

    settings

    assert_response :success
    assert_select "textarea[name=license_token]"
  end

  test "an env-supplied licence accepts a newer one pasted in" do
    env_pinned

    post ops_license_path, params: {license_token: "eyJhbGciOiJSUzI1NiJ9.whatever"}

    # Refused for being unverifiable, not for coming from the wrong place —
    # the distinction the alert has to make.
    assert_no_match(/hosted plan/, flash[:alert].to_s)
  end

  # The hosted service is the exception: its licence belongs to whoever runs
  # the box, not to the customer reading the screen.
  test "the hosted plan offers no form for the INSTALLATION's licence" do
    env_pinned(tier: "unlimited")

    settings

    # By id, not by name: the customer's own plan form posts under the same
    # field name, and asserting on the name would have said "no form at all"
    # the moment that section existed.
    assert_select "textarea#license-token", false
    assert_includes response.body, "managed by whoever operates it"
  end

  test "the hosted plan refuses a write, even a direct one" do
    env_pinned(tier: "unlimited")

    post ops_license_path, params: {license_token: "eyJhbGciOiJSUzI1NiJ9.whatever"}

    assert_match(/hosted plan/, flash[:alert])
    assert_equal 0, Ops::License.count
  end

  # REVERSED on 2026-09-01, deliberately. This used to assert that a hosted
  # customer saw "Unlimited · voodu-hosted" — the installation's tier and our
  # own customer id — on the grounds that people should see what they are
  # running. In practice it sat directly above a Limits row reading "0 invites"
  # that came from THEIR plan, so the card named two subjects and contradicted
  # itself: unlimited, and nothing.
  #
  # The installation is not the tenant's, the same way the SSO screen and the
  # topbar badge are not. What they get is their own plan, and a line saying
  # who to ask about the rest.
  test "the installation's tier and customer id are not shown to a tenant" do
    env_pinned(tier: "unlimited")

    settings

    assert_not_includes response.body, "Unlimited · voodu-hosted"
    assert_not_includes response.body, "voodu-hosted-dev"
    assert_includes response.body, "Your plan"
  end

  test "a licence with no tier claim reads as Enterprise" do
    env_pinned

    settings

    assert_includes response.body, "Enterprise · voodu-hosted"
  end

  # Forward compatibility: a tier this build has not heard of is still a
  # licence, and refusing to honour it would turn a new claim into an outage.
  test "an unknown tier falls back to Enterprise rather than failing" do
    env_pinned(tier: "galactic")

    settings

    assert_response :success
    assert_includes response.body, "Enterprise · voodu-hosted"
  end

  # ── Current, as the app-wide question ─────────────────────────────

  test "Current reports the tier for anything that needs to branch on it" do
    Rails.application.config.x.license = LicenseToken.new(status: :none)
    Current.reset

    assert Current.free?
    assert_not Current.licensed?

    env_pinned(tier: "unlimited")
    Current.reset

    assert Current.unlimited?
    assert Current.licensed?
    assert_not Current.enterprise?
    assert_not Current.free?
  end

  # The tiers must stay mutually exclusive: two of them true at once means
  # somewhere in the app both branches run.
  test "exactly one tier is ever true" do
    [nil, "enterprise", "unlimited"].each do |tier|
      if tier
        env_pinned(tier: tier)
      else
        Rails.application.config.x.license = LicenseToken.new(status: :none)
      end

      Current.reset

      assert_equal 1, [Current.free?, Current.enterprise?, Current.unlimited?].count(true),
        "tier #{tier.inspect} matched more or fewer than one predicate"
    end
  end

  # ── Issuing ───────────────────────────────────────────────────────

  # The tier has to survive a round trip through the issuer, or the hosted
  # plan cannot be created at all — the reader knew about `tier` before the
  # writer did.
  test "a tier issued by the rake task is the tier the app reads" do
    key = OpenSSL::PKey::RSA.generate(2048)
    claims = {"sub" => "voodu-hosted", "iat" => Time.current.to_i,
              "exp" => 365.days.from_now.to_i, "ent" => {}, "tier" => "unlimited"}
    token = JWT.encode(claims, key, "RS256")

    license = LicenseToken.resolve(token, key: key.public_key)

    assert_equal "unlimited", license.tier
    assert license.unlimited?
  end

  # `tier` names the product and must NOT be filed as an entitlement, where
  # nothing would ever read it.
  test "the tier is a top-level claim, not an entitlement" do
    key = OpenSSL::PKey::RSA.generate(2048)
    token = JWT.encode(
      {"sub" => "x", "iat" => Time.current.to_i, "exp" => 30.days.from_now.to_i,
       "ent" => {"tier" => "unlimited"}}, key, "RS256"
    )

    license = LicenseToken.resolve(token, key: key.public_key)

    assert_equal "enterprise", license.tier,
      "a tier hidden inside ent must not be honoured — it is not where the app looks"
  end

  # ── The customer's plan, on the hosted service ────────────────────

  test "the hosted service shows the customer their own plan, editable" do
    env_pinned(tier: "unlimited")

    settings

    assert_select "textarea#plan-token"
    assert_includes response.body, "Your plan"
  end

  # Self-hosted has no plans: the licence on the box already says what the
  # operator has, and a second answer could only disagree with it.
  test "a self-hosted installation shows no plan section" do
    Rails.application.config.x.license = LicenseToken.new(
      status: :valid, claims: {"sub" => "acme", "exp" => 30.days.from_now.to_i}, source: :database
    )

    settings

    assert_select "textarea#plan-token", false
    assert_not_includes response.body, "Your plan"
  end

  test "activating a plan on a self-hosted installation is refused" do
    Rails.application.config.x.license = LicenseToken.new(
      status: :valid, claims: {"sub" => "acme", "exp" => 30.days.from_now.to_i}
    )

    post ops_license_path, params: {scope: "plan", license_token: "whatever"}

    assert_match(/hosted service/, flash[:alert])
  end

  # The wrong-account refusal reaches the operator by name, so somebody handed
  # the wrong file knows which one they were handed.
  test "a plan licence for another account is refused by name" do
    env_pinned(tier: "unlimited")

    post ops_license_path, params: {scope: "plan", license_token: "not-a-token"}

    assert_match(/could not be verified/, flash[:alert])
  end
end
