# frozen_string_literal: true

require "test_helper"

# The confirmation screen, from the operator's side.
#
# What it protects: an installation that ran anonymously has one local operator
# holding every org. The first Clowk sign-in is a stranger to that row. Sending
# them to onboarding would have them build a SECOND workspace beside the one
# they came to claim, while the first became unreachable — so the redirect that
# sends them here instead is the load-bearing part, not the screen.
class AuthMigrationTest < ActionDispatch::IntegrationTest
  setup do
    sign_out
    @operator = User.create!(email: User::LOCAL_OPERATOR_EMAIL, name: "Local operator",
      email_verified: false)
    @org = Account.provision!(owner: @operator, account_name: "Local", org_name: "Default")

    @config = AuthConfig.create!(publishable_key: "pk_live_abc",
      pending_owner_email: "newowner@company.com")
  end

  def sign_in_as_claimant = sign_in_as(email: "newowner@company.com", name: "New Owner")

  def sign_in_as_stranger = sign_in_as(email: "stranger@company.com", name: "Stranger")

  test "the named person is offered the workspace instead of onboarding" do
    sign_in_as_claimant

    get root_path

    assert_redirected_to auth_migration_path
  end

  test "the screen names what is being handed over" do
    sign_in_as_claimant

    get auth_migration_path

    assert_response :success
    assert_includes response.body, "Take over this workspace"
    assert_includes response.body, "newowner@company.com"
  end

  # Anyone else signing in must see the ordinary first-run path, not an offer to
  # take over somebody else's installation.
  test "a stranger is sent to onboarding, not to the offer" do
    sign_in_as_stranger

    get root_path

    assert_redirected_to new_onboarding_path

    get auth_migration_path

    assert_redirected_to root_path(org_id: nil, server_key: nil)
  end

  test "confirming hands over the orgs and the account" do
    sign_in_as_claimant

    post auth_migration_path

    claimant = User.find_by!(email: "newowner@company.com")

    assert_equal 1, claimant.active_orgs.count
    assert_equal claimant.id, @org.reload.account.reload.owner_id
    assert_equal 0, @operator.reload.active_orgs.count
    assert_not_nil @config.reload.migrated_at
  end

  test "after confirming, the offer is gone and normal routing resumes" do
    sign_in_as_claimant
    post auth_migration_path

    get auth_migration_path

    assert_redirected_to root_path(org_id: nil, server_key: nil)
  end

  # A second person signing in later must not be offered a workspace that has
  # already been claimed.
  test "a claimed workspace is not offered again to anyone" do
    sign_in_as_claimant
    post auth_migration_path
    sign_out

    sign_in_as(email: "newowner@company.com", name: "Same person, later")
    get auth_migration_path

    assert_redirected_to root_path(org_id: nil, server_key: nil)
  end
end
