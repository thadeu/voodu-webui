# frozen_string_literal: true

require "test_helper"

# The other half of the perimeter warning: with sign-in ON, a public address is
# just the internet arriving at a login page — normal, and not worth shouting
# about. Without this test the banner could be keyed on the address alone and
# nobody would notice it firing for every SaaS visitor.
class PerimeterBannerSignedInTest < ActionDispatch::IntegrationTest
  test "the warning never fires when sign-in is the door" do
    assert Rails.application.config.x.clowk_enabled, "this test needs the flag on"

    sign_in_as(email: users(:owner).email)

    get server_root_path(org_id: "acmeorg1", server_key: servers(:alpha).key),
      headers: {"REMOTE_ADDR" => "54.20.48.217"}

    assert_response :success
    assert_not_includes response.body, "No sign-in required"
  end
end
