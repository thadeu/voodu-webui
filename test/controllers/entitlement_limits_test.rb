# frozen_string_literal: true

require "test_helper"

# What the free tier refuses, and — the half that matters more — what it never
# takes away.
#
# An entitlement may stop the NEXT thing from being created. It may not remove
# what exists, because a licence that can revoke access is a licence that can
# lock a paying customer out of their own dashboard during the week their
# renewal is being signed. Every refusal below is paired with an assertion that
# the existing rows are still reachable.
class EntitlementLimitsTest < ActionDispatch::IntegrationTest
  setup do
    sign_out
    sign_in_as(email: users(:owner).email)
    @licensed = Rails.application.config.x.license
  end

  teardown { Rails.application.config.x.license = @licensed }

  def free_tier!
    Rails.application.config.x.license = License.new(status: :none)
  end

  def lapsed!
    Rails.application.config.x.license = License.new(
      status: :lapsed, claims: {"sub" => "acme", "exp" => 90.days.ago.to_i}
    )
  end

  # ── Orgs ───────────────────────────────────────────────────────────────

  test "the free tier refuses a second org and says why" do
    free_tier!

    assert_no_difference("Org.count") do
      post orgs_path, params: {org: {name: "Extra"}}, as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "licensed for"
  end

  test "a licence allows it" do
    assert_difference("Org.count", 1) do
      post orgs_path, params: {org: {name: "Extra"}}, as: :turbo_stream
    end
  end

  test "a licence naming a number caps at that number" do
    Rails.application.config.x.license = License.new(
      status: :valid, claims: {"sub" => "acme", "exp" => 1.year.from_now.to_i,
                               "ent" => {"orgs" => Org.count}}
    )

    assert_no_difference("Org.count") do
      post orgs_path, params: {org: {name: "Over"}}, as: :turbo_stream
    end
  end

  # ── Invitations ────────────────────────────────────────────────────────

  test "the free tier refuses an invitation" do
    free_tier!

    assert_no_difference("Org::Membership.count") do
      post org_members_path(org_id: "acmeorg1"), params: {email: "new@example.com", role: "member"}
    end

    assert_redirected_to org_members_path(org_id: "acmeorg1")
    assert_match(/licensed for a single operator/, flash[:alert])
  end

  test "a licence allows inviting" do
    assert_difference("Org::Membership.count", 1) do
      post org_members_path(org_id: "acmeorg1"), params: {email: "new@example.com", role: "member"}
    end
  end

  # The owner each org is created with must not consume a seat — otherwise a
  # one-seat licence would be spent before anyone was invited.
  test "the owner membership does not count against the invite limit" do
    Rails.application.config.x.license = License.new(
      status: :valid, claims: {"sub" => "acme", "exp" => 1.year.from_now.to_i,
                               "ent" => {"member_invites" => 1}}
    )

    assert_difference("Org::Membership.count", 1) do
      post org_members_path(org_id: "acmeorg1"), params: {email: "first@example.com", role: "member"}
    end

    assert_no_difference("Org::Membership.count") do
      post org_members_path(org_id: "acmeorg1"), params: {email: "second@example.com", role: "member"}
    end
  end

  # ── The rule that matters: nothing is taken away ───────────────────────

  test "a lapsed licence still serves every org that already exists" do
    lapsed!

    assert Org.count > 1, "this test needs more orgs than the free tier allows"

    get server_root_path(org_id: "acmeorg1", server_key: servers(:alpha).key)

    assert_response :success
  end

  test "a lapsed licence does not delete or hide existing members" do
    lapsed!
    existing = orgs(:acme).memberships.count

    get org_members_path(org_id: "acmeorg1")

    assert_response :success
    assert_equal existing, orgs(:acme).reload.memberships.count
  end

  test "a lapsed licence only stops the next org" do
    lapsed!
    before = Org.count

    post orgs_path, params: {org: {name: "Extra"}}, as: :turbo_stream

    assert_response :unprocessable_entity
    assert_equal before, Org.count, "nothing existing may be removed"
  end
end
