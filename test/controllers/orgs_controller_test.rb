# frozen_string_literal: true

require "test_helper"

# OrgsController — CRUD answering turbo_stream. Scenarios: create appends the
# dropdown option + refreshes the panel; a blank name is rejected without a
# record; rename updates; delete removes; delete is blocked when the org still
# owns servers (the guard). Asserts on the turbo-stream targets so a change to
# what streams back breaks the test.
class OrgsControllerTest < ActionDispatch::IntegrationTest
  fixtures :orgs, :servers

  test "create adds the org and streams the new option + refreshed panel" do
    assert_difference -> { Org.count }, 1 do
      post orgs_path, params: {org: {name: "Staging", description: "stg"}}, as: :turbo_stream
    end

    assert_response :success
    org = Org.find_by!(name: "Staging")
    assert_match "org-opt-#{org.id}", @response.body
    assert_match "org-manager-panel", @response.body
  end

  test "create with a blank name re-renders the panel with an error and no record" do
    assert_no_difference -> { Org.count } do
      post orgs_path, params: {org: {name: ""}}, as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_match "org-manager-panel", @response.body
  end

  test "update renames the org" do
    org = orgs(:globex)

    patch org_path(org), params: {org: {name: "Globex Intl"}}, as: :turbo_stream

    assert_response :success
    assert_equal "Globex Intl", org.reload.name
    assert_match "org-opt-#{org.id}", @response.body
  end

  test "destroy removes an org that owns no servers" do
    org = orgs(:voidco) # owns nothing (globex owns gamma)

    assert_difference -> { Org.count }, -1 do
      delete org_path(org), as: :turbo_stream
    end

    assert_response :success
  end

  test "destroy is blocked when the org still owns servers" do
    org = orgs(:acme) # owns alpha + beta

    assert_no_difference -> { Org.count } do
      delete org_path(org), as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert Org.exists?(org.id)
  end
end
