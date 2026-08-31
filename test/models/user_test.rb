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

  # A VERIFIED address is the identity, whichever provider carried it.
  #
  # Signing up with Google and later signing in with GitHub on the same address
  # is one person, and the two hand us different subjects. Treating them as two
  # accounts meant the second sign-in tried to insert a duplicate address and
  # died with "Email has already been taken" — on a service with open sign-up,
  # not an edge case.
  #
  # This test used to assert the opposite, as defence in depth: it refused to
  # bind a second subject to an address already bound. That refusal is gone by
  # decision, and what remains standing between an address and somebody else's
  # orgs is `email_verified` ALONE. It is now load-bearing rather than a second
  # opinion: a provider that could assert verified for an address it had not
  # checked would be handing over accounts. The test below is the other half.
  test "a verified address is the same person, whichever provider carried it" do
    first = User.provision_from_clowk!(CLAIMS)

    second = User.provision_from_clowk!(CLAIMS.merge(sub: "clowk-sub-GITHUB", provider: "github"))

    assert_equal first.id, second.id, "one address is one person"
    assert_equal "clowk-sub-GITHUB", second.reload.clowk_user_id,
      "the subject follows the address — nothing else in the app keys off it"
  end

  # The half that must never move. An unverified address is an assertion, not a
  # fact, and matching on one would hand over whatever that address already
  # owns.
  test "an unverified address never adopts an existing account" do
    owner = User.provision_from_clowk!(CLAIMS)

    intruder = User.provision_from_clowk!(
      CLAIMS.merge(sub: "clowk-sub-INTRUDER", email_verified: false)
    )

    assert_not_equal owner.id, intruder.id
    assert intruder.email.end_with?(User::PLACEHOLDER_EMAIL_SUFFIX),
      "an unproven address must not even be recorded as the address"
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
