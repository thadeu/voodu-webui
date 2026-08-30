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
end
