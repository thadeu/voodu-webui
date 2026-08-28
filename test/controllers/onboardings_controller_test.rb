# frozen_string_literal: true

require "test_helper"

# A first sign-in reaches nothing: membership is the only source of access, so
# a person with no org has no servers, no dashboards and no way in. This is the
# one screen that can change that.
class OnboardingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_out
    sign_in_as(email: "newcomer@example.com", name: "Newcomer")
  end

  test "a person with no org lands on onboarding from the root" do
    get root_path(org_id: nil, server_key: nil)

    assert_redirected_to new_onboarding_path
  end

  test "the form renders without any tenant context" do
    get new_onboarding_path

    assert_response :success
    assert_includes @response.body, "Set up your workspace"
  end

  # Without this the screen is a dead end for anyone who signed in as the wrong
  # identity — the only other way out is clearing a cookie by hand.
  test "the form offers a way out" do
    get new_onboarding_path

    assert_response :success
    assert_includes @response.body, "newcomer@example.com"
    assert_includes @response.body, Clowk.config.mount_path + "/sign_out"
  end

  test "creating a workspace makes an account, an org and the owner membership" do
    assert_difference(["Account.count", "Org.count", "Org::Membership.count"], 1) do
      post onboarding_path, params: {account_name: "Newco", org_name: "Production"}
    end

    account = Account.find_by(name: "Newco")
    org = account.orgs.sole
    membership = org.memberships.sole

    assert_equal User.find_by(email: "newcomer@example.com"), account.owner
    assert_equal account.owner, membership.user
    assert membership.owner?
    assert membership.active?, "an invited membership would grant nothing"
    assert_redirected_to org_root_path(org_id: org.short_id)
  end

  # Nothing half-built: an account with no org is a dead end, and an org with no
  # owner membership is an org nobody can reach.
  test "a blank org name creates neither the account nor the org" do
    assert_no_difference(["Account.count", "Org.count"]) do
      post onboarding_path, params: {account_name: "Newco", org_name: "  "}
    end

    assert_response :unprocessable_entity
  end

  test "someone who already belongs somewhere is sent away" do
    sign_out
    sign_in_as # the default operator, who owns acme

    get new_onboarding_path

    assert_response :redirect
    assert_no_difference("Account.count") do
      post onboarding_path, params: {account_name: "Second", org_name: "Org"}
    end
  end
end
