# frozen_string_literal: true

require "test_helper"

# Who is let in at all.
#
# Signing in proves identity; it says nothing about belonging. Without this
# every identity a Clowk instance will authenticate got a user row on the box —
# reaching nothing, since membership is the only source of access, but
# accumulating invisibly because a row in no org appears on no screen.
class AdmissionTest < ActiveSupport::TestCase
  ENTERPRISE = LicenseToken.new(
    status: :valid, claims: {"sub" => "acme", "exp" => 1.year.from_now.to_i}
  )

  # A self-hosted box whose one account is taken: the invite-only case.
  def settled = Entitlements.for(nil, ENTERPRISE)

  def claims(email: "someone@example.com", verified: true, sub: "clowk-new")
    {sub: sub, email: email, email_verified: verified, name: "Someone"}
  end

  def decide(**overrides) = Admission.decide(claims(**overrides), entitlements: settled)

  test "a stranger is refused when the installation is settled" do
    decision = decide

    assert_not decision.allowed?
    assert_equal :no_invitation, decision.reason
  end

  test "somebody who already signed in here is let in" do
    decision = Admission.decide(
      claims(email: users(:owner).email, sub: users(:owner).clowk_user_id),
      entitlements: settled
    )

    assert decision.allowed?
    assert_equal :member, decision.reason
  end

  # The allowlist itself: an invitation is what an administrator issues to say
  # "this address may be here".
  test "an invited address is let in before the invitation is accepted" do
    invited = User.create!(email: "invited@example.com")
    orgs(:acme).memberships.create!(user: invited, role: :member, status: :invited,
      invited_at: Time.current, invited_by: users(:owner))

    decision = decide(email: "invited@example.com")

    assert decision.allowed?
    assert_equal :invited, decision.reason
  end

  # An unverified address is an assertion, not a fact. Matching on one would let
  # anybody who can get a provider to echo an address walk into the org that
  # address was invited to.
  test "an unverified address never matches an invitation" do
    invited = User.create!(email: "invited2@example.com")
    orgs(:acme).memberships.create!(user: invited, role: :member, status: :invited,
      invited_at: Time.current, invited_by: users(:owner))

    decision = decide(email: "invited2@example.com", verified: false)

    assert_not decision.allowed?
  end

  # Without this the product bricks: a freshly installed box with sign-in
  # already on would let nobody in, including the operator who installed it.
  test "a fresh installation lets the first person in" do
    # In dependency order. Account has dependent: :restrict_with_error on orgs,
    # so destroy_all there fails SILENTLY — it records an error and leaves the
    # row, which reads as "cleared" and is not.
    Server.delete_all
    Org::Membership.delete_all
    Org.delete_all
    Account.delete_all

    decision = Admission.decide(claims, entitlements: Entitlements.for(nil, ENTERPRISE))

    assert decision.allowed?
    assert_equal :open_signup, decision.reason
  end

  # And the hosted service could never take a customer.
  test "the hosted service admits anyone, because open sign-up is the product" do
    hosted = LicenseToken.new(status: :valid,
      claims: {"sub" => "hosted", "exp" => 1.year.from_now.to_i, "tier" => "unlimited"})

    decision = Admission.decide(claims, entitlements: Entitlements.for(nil, hosted))

    assert decision.allowed?
    assert_equal :open_signup, decision.reason
  end

  # The anonymous → Clowk handover. This person has no membership and no
  # invitation BY CONSTRUCTION: the workspace they are claiming belongs to the
  # local operator, and the handover happens after they sign in. Refusing would
  # strand every server and token in it.
  test "the person the handover named is let in" do
    Ops::SsoConfig.create!(provider: "clowk", publishable_key: "pk_live_x",
      pending_owner_email: "claimant@example.com")

    decision = decide(email: "claimant@example.com")

    assert decision.allowed?
    assert_equal :claiming_workspace, decision.reason
  end

  test "somebody else is not let in by a pending handover" do
    Ops::SsoConfig.create!(provider: "clowk", publishable_key: "pk_live_x",
      pending_owner_email: "claimant@example.com")

    assert_not decide(email: "opportunist@example.com").allowed?
  end
end
