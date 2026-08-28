# frozen_string_literal: true

require "test_helper"

# provision_from_clowk! is where an external identity becomes a local row, so
# it is where account takeover would live if it lived anywhere. Each test below
# names the takeover it prevents.
class UserTest < ActiveSupport::TestCase
  CLAIMS = {
    sub: "clowk-sub-1", email: "ada@example.com", email_verified: true,
    name: "Ada", avatar_url: "https://img.example/ada.png", provider: "github"
  }.freeze

  test "mirrors a subject onto a new row" do
    user = User.provision_from_clowk!(CLAIMS)

    assert_equal "clowk-sub-1", user.clowk_user_id
    assert_equal "ada@example.com", user.email
    assert_equal "Ada", user.name
    assert user.email_verified?
    assert_not_nil user.last_signed_in_at
  end

  test "provisioning the same subject twice reuses the row" do
    first = User.provision_from_clowk!(CLAIMS)

    assert_no_difference("User.count") do
      assert_equal first.id, User.provision_from_clowk!(CLAIMS).id
    end
  end

  test "claims an unbound row by address so an invite survives first sign-in" do
    invited = User.create!(email: "ada@example.com")

    user = User.provision_from_clowk!(CLAIMS)

    assert_equal invited.id, user.id, "the invitation's row must be claimed, not duplicated"
    assert_equal "clowk-sub-1", user.reload.clowk_user_id
  end

  # The takeover: a provider that lets someone assert an arbitrary address would
  # otherwise hand them the row that address already belongs to.
  test "refuses to claim a row already bound to a different subject" do
    User.create!(email: "ada@example.com", clowk_user_id: "clowk-sub-OTHER")

    assert_raises(ActiveRecord::RecordInvalid) { User.provision_from_clowk!(CLAIMS) }
    assert_equal "clowk-sub-OTHER", User.find_by(email: "ada@example.com").clowk_user_id
  end

  # An unproven address is a claim on a string, not a person.
  test "an unverified address does not claim an invited row" do
    invited = User.create!(email: "ada@example.com")

    user = User.provision_from_clowk!(CLAIMS.merge(email_verified: false))

    assert_not_equal invited.id, user.id
    assert_nil invited.reload.clowk_user_id
  end

  test "a placeholder address never claims an existing row" do
    placeholder = "someone#{User::PLACEHOLDER_EMAIL_SUFFIX}"
    existing = User.create!(email: placeholder)

    user = User.provision_from_clowk!(CLAIMS.merge(email: placeholder))

    assert_not_equal existing.id, user.id
    assert_equal "clowk-sub-1#{User::PLACEHOLDER_EMAIL_SUFFIX}", user.email
  end

  # Two subjects can arrive holding the same placeholder; deriving ours from
  # `sub` is what keeps them apart on the unique index.
  test "two blank-email subjects do not collide" do
    a = User.provision_from_clowk!(sub: "sub-a", email: nil, email_verified: false)
    b = User.provision_from_clowk!(sub: "sub-b", email: nil, email_verified: false)

    assert_not_equal a.id, b.id
    assert_not_equal a.email, b.email
  end

  test "a placeholder never overwrites a real address" do
    user = User.provision_from_clowk!(CLAIMS)

    User.provision_from_clowk!(CLAIMS.merge(email: "x#{User::PLACEHOLDER_EMAIL_SUFFIX}"))

    assert_equal "ada@example.com", user.reload.email
  end

  test "refuses claims without a subject" do
    assert_raises(ArgumentError) { User.provision_from_clowk!(email: "ada@example.com") }
  end

  test "verified_email? refuses a placeholder even when the claim says verified" do
    user = User.new(email: "x#{User::PLACEHOLDER_EMAIL_SUFFIX}", email_verified: true)

    assert_not user.verified_email?
  end
end
