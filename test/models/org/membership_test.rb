# frozen_string_literal: true

require "test_helper"

class Org
  class MembershipTest < ActiveSupport::TestCase
    # The integer mapping is load-bearing: Permissions compares roles by order,
    # so a reorder would silently re-grade everyone.
    test "exposes the role and status enums in a fixed order" do
      assert_equal({"member" => 0, "admin" => 1, "owner" => 2}, Org::Membership.roles)
      assert_equal({"invited" => 0, "active" => 1}, Org::Membership.statuses)
    end

    test "one membership per user and org" do
      duplicate = Org::Membership.new(
        user: users(:owner), org: orgs(:acme), role: :member, status: :active
      )

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:user_id], "has already been taken"
    end

    test "a bogus role is a validation error, not a raise" do
      membership = Org::Membership.new(user: users(:invitee), org: orgs(:voidco))
      membership.role = :superuser

      assert_not membership.valid?
    rescue ArgumentError
      flunk "a forged form value must not raise"
    end

    # An org whose last admin-or-owner leaves is unreachable by ANYONE:
    # membership is the only source of access, and the account owner's title
    # grants nothing. Its servers keep being polled with live PATs.
    test "the last active privileged member cannot be removed" do
      membership = org_memberships(:owner_in_voidco)

      assert_not membership.destroy
      assert Org::Membership.exists?(membership.id)
    end

    test "the last active privileged member cannot be demoted" do
      membership = org_memberships(:owner_in_voidco)

      assert_not membership.update(role: :member)
      assert membership.reload.owner?
    end

    test "a privileged member can leave once another one remains" do
      orgs(:voidco).memberships.create!(user: users(:outsider), role: :admin, status: :active)

      assert org_memberships(:owner_in_voidco).destroy
    end

    # An INVITED admin is not a member yet, so it cannot be what keeps the org
    # reachable — the guard counts active rows only.
    test "an invited privileged member does not count as the last one" do
      orgs(:voidco).memberships.create!(user: users(:outsider), role: :admin, status: :invited)

      assert_not org_memberships(:owner_in_voidco).destroy
    end

    # Deleting the org itself must not be blocked by the guard that protects
    # against being locked out of it.
    test "destroying the org takes its memberships with it" do
      assert orgs(:voidco).destroy
      assert_empty Org::Membership.where(org_id: orgs(:voidco).id)
    end

    test "the invite token round-trips and is purpose-scoped" do
      membership = org_memberships(:invitee_in_acme)

      assert_equal membership, Org::Membership.find_invited(membership.invite_token)
      assert_nil Org::Membership.find_invited(membership.signed_id(purpose: :something_else))
    end

    test "an expired invite token does not resolve" do
      membership = org_memberships(:invitee_in_acme)
      token = membership.invite_token

      travel(Org::Membership::INVITE_MAX_AGE + 1.day) do
        assert_nil Org::Membership.find_invited(token)
      end
    end
  end
end
