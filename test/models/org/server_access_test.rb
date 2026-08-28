# frozen_string_literal: true

require "test_helper"

class Org
  class ServerAccessTest < ActiveSupport::TestCase
    # The row a scoping bug would forge. Without org_id and this validation,
    # `membership.server_accesses` — which FEELS scoped because you arrived
    # through the membership — would hand acme's member a live PAT for globex's
    # controller.
    test "refuses a membership and server from different orgs" do
      grant = Org::ServerAccess.new(
        membership: org_memberships(:contractor_in_acme),
        server: servers(:gamma), # globex
        org: orgs(:acme)
      )

      assert_not grant.valid?
      assert_includes grant.errors[:base], "membership and server must belong to the same org"
    end

    test "refuses when the grant's own org disagrees with the membership" do
      grant = Org::ServerAccess.new(
        membership: org_memberships(:contractor_in_acme),
        server: servers(:alpha),
        org: orgs(:globex)
      )

      assert_not grant.valid?
    end

    test "accepts a server in the membership's own org" do
      grant = Org::ServerAccess.new(
        membership: org_memberships(:contractor_in_acme),
        server: servers(:beta),
        org: orgs(:acme)
      )

      assert grant.valid?, grant.errors.full_messages.to_sentence
    end

    test "one grant per membership and server" do
      duplicate = Org::ServerAccess.new(
        membership: org_memberships(:contractor_in_acme),
        server: servers(:alpha),
        org: orgs(:acme)
      )

      assert_not duplicate.valid?
    end

    # servers.id is a SQLite rowid and rowids are REUSED. A grant that outlived
    # its server would silently apply to whatever took the id next.
    test "a grant does not outlive its server" do
      grant = org_server_accesses(:contractor_alpha)

      servers(:alpha).destroy

      assert_not Org::ServerAccess.exists?(grant.id)
    end

    test "a grant does not outlive its membership" do
      grant = org_server_accesses(:contractor_alpha)

      org_memberships(:contractor_in_acme).destroy

      assert_not Org::ServerAccess.exists?(grant.id)
    end
  end
end
