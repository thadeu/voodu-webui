# frozen_string_literal: true

require "test_helper"

# Two screens, each named for its subject rather than its scope.
#
# They were one screen called "Installation", which described where the settings
# apply and not what they are — and nobody looking for "how do I turn on SSO"
# searches for that. One is what you bought; the other is how people get in.
class InstallationScreensTest < ActionDispatch::IntegrationTest
  setup do
    sign_out
    sign_in_as(email: users(:owner).email)
  end

  test "the licence screen is about the licence" do
    get license_path

    assert_response :success
    assert_includes response.body, "License"
    assert_includes response.body, "Plan"
    assert_not_includes response.body, "Turn on sign-in"
  end

  test "the SSO screen is about sign-in" do
    get sso_path

    assert_response :success
    assert_includes response.body, "Single sign-on"
    assert_includes response.body, "Sign-in"
  end

  # Neither is a property of a server, and an operator with none is exactly who
  # is about to buy.
  test "both are reachable with no server registered" do
    Server.delete_all

    [license_path, sso_path].each do |path|
      get path

      assert_response :success, "#{path} must not need a server"
    end
  end

  test "both are offered in the account menu and the sidebar" do
    get server_root_path(org_id: "acmeorg1", server_key: servers(:alpha).key)

    assert_response :success
    # Literal paths: license_path picks up the suite's default org_id and would
    # assert against a query string the markup does not (and must not) carry.
    assert_includes response.body, %(href="/ops/license")
    assert_includes response.body, %(href="/ops/sso")
  end

  # The account menu does not exist in anonymous mode, so the sidebar is the
  # only way in — and the free tier is precisely who goes looking for the
  # licence screen. Without the sidebar entry this is unreachable.
  test "the sidebar still offers them when there is no account menu" do
    previous = Rails.application.config.x.clowk_enabled
    Rails.application.config.x.clowk_enabled = false
    sign_out

    org = User.local_operator.active_orgs.sole
    server = org.servers.create!(name: "s", endpoint: "http://10.4.4.4:8687", pat: "x")
    get server_root_path(org_id: org.short_id, server_key: server.key)

    assert_response :success
    assert_not_includes response.body, "Sign out", "the account menu should be gone"
    assert_includes response.body, %(href="/ops/license"), "…so the sidebar has to carry it"
  ensure
    Rails.application.config.x.clowk_enabled = previous
  end
end
