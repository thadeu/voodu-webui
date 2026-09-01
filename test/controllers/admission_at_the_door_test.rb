# frozen_string_literal: true

require "test_helper"

# Admission at the door, over HTTP.
#
# The unit tests cover the decision; this covers the thing that only shows up
# in a request: that a refused identity leaves NO ROW behind. That is the whole
# point — a row in no org reaches nothing, but appears on no screen either, so
# they pile up unseen on any box pointed at a Clowk instance whose users are
# not all supposed to be here.
class AdmissionAtTheDoorTest < ActionDispatch::IntegrationTest
  ENTERPRISE = LicenseToken.new(
    status: :valid, claims: {"sub" => "cliente", "exp" => 1.year.from_now.to_i}
  )

  setup do
    @installed = Rails.application.config.x.license
    Rails.application.config.x.license = ENTERPRISE
    Current.reset
  end

  # The suite's default licence is what gets left behind otherwise, and the
  # next test to read it as "how this box is licensed" measures this one.
  teardown { Rails.application.config.x.license = @installed }

  # Only the cookie — NOT test_helper's sign_in_as, which calls
  # provision_from_clowk! itself and would create the very row under test.
  # A browser arrives with a token and nothing else.
  def arrive_as(email, sub: "clowk-#{SecureRandom.hex(4)}")
    cookies[Clowk.config.cookie_key] = ClowkDevToken.mint(
      sub: sub, email: email, name: "X", email_verified: true
    )
  end

  test "a stranger is refused and leaves no row behind" do
    assert_no_difference "User.count" do
      arrive_as("nobody@internet.example")
      get root_path(org_id: nil, server_key: nil)
    end

    assert_response :forbidden
  end

  # A wall with no explanation sends somebody to support. This says what
  # happened and which address to have invited.
  test "the refusal explains itself and names the address" do
    arrive_as("nobody@internet.example")

    get root_path(org_id: nil, server_key: nil)

    assert_includes response.body, "You need an invitation"
    assert_includes response.body, "nobody@internet.example"
    assert_includes response.body, "Sign out"
  end

  test "an invited address is let through" do
    invited = User.create!(email: "invited@example.com")
    orgs(:acme).memberships.create!(user: invited, role: :member, status: :invited,
      invited_at: Time.current, invited_by: users(:owner))

    arrive_as("invited@example.com")
    get root_path(org_id: nil, server_key: nil)

    assert_not_equal 403, response.status
  end

  # Somebody already inside is never re-evaluated against a list they predate.
  test "an existing member is let through" do
    arrive_as(users(:owner).email, sub: users(:owner).clowk_user_id)

    get root_path(org_id: nil, server_key: nil)

    assert_not_equal 403, response.status
  end
end
