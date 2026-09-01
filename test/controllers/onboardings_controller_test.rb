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
    with_room_for_another_account do
      get new_onboarding_path

      assert_response :success
      assert_includes @response.body, "Set up your workspace"
    end
  end

  # Without this the screen is a dead end for anyone who signed in as the wrong
  # identity — the only other way out is clearing a cookie by hand.
  test "the form offers a way out" do
    with_room_for_another_account do
      get new_onboarding_path

      assert_response :success
      assert_includes @response.body, "newcomer@example.com"
      assert_includes @response.body, Clowk.config.mount_path + "/sign_out"
    end
  end

  # The installation holds ONE account now, in every self-hosted tier, and the
  # fixtures already use it up. This test is about the mechanics of onboarding,
  # so it buys room explicitly rather than asserting the cap — the cap has its
  # own test below.
  def with_room_for_another_account
    previous = Rails.application.config.x.license
    Rails.application.config.x.license = LicenseToken.new(
      status: :valid,
      claims: {"sub" => "roomy", "exp" => 30.days.from_now.to_i, "ent" => {"accounts" => nil}}
    )

    yield
  ensure
    Rails.application.config.x.license = previous
  end

  # Refused BEFORE the form, not as an error on top of it: a form that cannot
  # succeed invites somebody to name a workspace and only then learn it was
  # never possible.
  test "an installation with its one account already taken offers no form at all" do
    get new_onboarding_path

    assert_response :forbidden
    assert_includes @response.body, "You need an invitation"
    assert_select "input[name=account_name]", false
  end

  # The form is not the control. Someone who opened the page before the last
  # account existed, or who posts directly, is refused here too.
  test "posting directly is refused as well" do
    assert_no_difference("Account.count") do
      post onboarding_path, params: {account_name: "Second", org_name: "Nope"}
    end

    assert_response :forbidden
    assert_includes @response.body, "You need an invitation"
  end

  # The page names the address to invite, so the person asking knows what to
  # ask for and the person granting knows what to type.
  test "the refusal names the address that needs inviting" do
    get new_onboarding_path

    assert_includes @response.body, "newcomer@example.com"
    assert_includes @response.body, Clowk.config.mount_path + "/sign_out"
  end

  test "creating a workspace makes an account, an org and the owner membership" do
    with_room_for_another_account do
      assert_difference(["Account.count", "Org.count", "Org::Membership.count"], 1) do
        post onboarding_path, params: {account_name: "Newco", org_name: "Production"}
      end
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
