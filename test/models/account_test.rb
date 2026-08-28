# frozen_string_literal: true

require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "an account groups orgs and names a principal" do
    account = accounts(:acme_co)

    assert_equal users(:owner), account.owner
    assert_includes account.orgs, orgs(:acme)
  end

  # Being in an account grants nothing — that is the whole reason cross-account
  # access needs no exception anywhere.
  test "the owner reaches an org only through a membership" do
    account = accounts(:acme_co)
    org = account.orgs.create!(name: "Unlinked")

    assert_not_includes account.owner.active_orgs, org
  end

  test "an account with orgs cannot be deleted out from under them" do
    assert_not accounts(:acme_co).destroy
    assert Account.exists?(accounts(:acme_co).id)
  end

  # ── Transfer ───────────────────────────────────────────────────────────

  test "transfers to someone who administers every org in the account" do
    account = accounts(:acme_co)
    heir = users(:contractor)
    account.orgs.each do |org|
      m = heir.membership_in(org) || org.memberships.create!(user: heir, status: :active)
      m.update!(role: :admin)
    end

    assert account.transfer_to!(heir)
    assert_equal heir, account.reload.owner
  end

  # The state the last-privileged-member guard exists to prevent, reached from
  # the other direction: a principal on paper who can open nothing.
  test "refuses someone who reaches none of the account's orgs" do
    error = assert_raises(ArgumentError) do
      accounts(:acme_co).transfer_to!(users(:outsider))
    end

    assert_match(/not an admin or owner/, error.message)
    assert_equal users(:owner), accounts(:acme_co).reload.owner
  end

  test "refuses someone who is only a plain member" do
    assert_raises(ArgumentError) { accounts(:acme_co).transfer_to!(users(:contractor)) }
  end

  test "refuses anything that is not a user" do
    assert_raises(ArgumentError) { accounts(:acme_co).transfer_to!(users(:owner).email) }
  end

  # restrict_with_error on the user side: deleting the person who still answers
  # for an account would leave it ownerless.
  test "the owner cannot be deleted while they still own it" do
    assert_not users(:owner).destroy
    assert User.exists?(users(:owner).id)
  end
end
