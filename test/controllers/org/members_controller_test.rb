# frozen_string_literal: true

require "test_helper"

class Org
  # The members screen is where access is handed out, so it is where privilege
  # escalation would live. The signed-in operator is acme's OWNER throughout —
  # these test the ceiling on what even the highest role may do.
  class MembersControllerTest < ActionDispatch::IntegrationTest
    ACME = "acmeorg1"

    setup { @acme = orgs(:acme) }

    # The screen used to be reachable only by typing its URL. It lives in the
    # sidebar's Org group now — members is per-org, and the topbar dropdown hid
    # it behind a click.
    # The literal href, closing quote included — not org_members_path, which in
    # an integration test inherits :server_key from the previous request and so
    # would assert the very pollution this pins against. The quote is what makes
    # it strict: `/acmeorg1/members?server_key=aaaaaa` fails it.
    #
    # That query string is not cosmetic. ApplicationController#default_url_options
    # injects :server_key from the path, so a route that has no such segment
    # picks one up anyway and it rides along in the URL bar and every log line.
    test "the sidebar links to it, with no server_key appended" do
      get server_root_path(org_id: ACME, server_key: servers(:alpha).key)

      assert_response :success
      assert_includes @response.body, %(href="/#{ACME}/members")
    end

    # /servers carries no :org_id, so Current.role is nil there — the sidebar
    # has to ask about the org it is pointing AT, or the owner loses the link
    # on the one page they land on with no server selected.
    # The literal path, not servers_path: the suite sets a global
    # default_url_options[:org_id], so the helper generates
    # `/servers?org_id=acmeorg1` — which puts an org in params and resolves
    # Current.role, hiding the very gap this pins. A browser sends no such
    # query.
    test "the link survives the server registry" do
      # /servers is the org-less door; it resolves an org and redirects there.
      get "/servers"
      follow_redirect!

      assert_response :success
      assert_includes @response.body, %(href="/#{ACME}/members")
    end

    test "a member sees no link to a screen that would refuse them" do
      sign_out
      sign_in_as(email: users(:contractor).email)

      get server_root_path(org_id: ACME, server_key: servers(:alpha).key)

      assert_response :success
      assert_not_includes @response.body, %(href="/#{ACME}/members")
    end

    test "the screen lists the org's members" do
      get org_members_path(org_id: ACME)

      assert_response :success
      assert_includes @response.body, users(:contractor).email
    end

    test "inviting creates a pending membership and shows a link to send" do
      assert_difference("Org::Membership.count", 1) do
        post org_members_path(org_id: ACME), params: {email: "new@example.com", role: "member"}
      end

      membership = Org::Membership.joins(:user).find_by(users: {email: "new@example.com"})

      assert membership.invited?, "an invitation must not grant access before it is accepted"
      assert membership.member?
      # The link lives on the row, not in the flash: it is derived from the
      # membership, and a 380-character URL in the session overflowed the cookie.
      get org_members_path(org_id: ACME)

      assert_match %r{/invites/}, @response.body
    end

    # owner is the account principal, set at signup. Not something an invite
    # form hands out, whatever the posted value says.
    test "an admin cannot mint an owner" do
      post org_members_path(org_id: ACME), params: {email: "climber@example.com", role: "owner"}

      membership = Org::Membership.joins(:user).find_by(users: {email: "climber@example.com"})

      assert membership.member?, "a forged role must fall back to the floor, not the ceiling"
    end

    test "an existing member is reported, not silently re-invited" do
      assert_no_difference("Org::Membership.count") do
        post org_members_path(org_id: ACME), params: {email: users(:contractor).email}
      end

      assert_match(/already/, flash[:alert].to_s)
    end

    test "a role change cannot promote to owner either" do
      patch org_member_path(org_id: ACME, id: org_memberships(:contractor_in_acme).id),
        params: {role: "owner"}

      assert org_memberships(:contractor_in_acme).reload.member?
    end

    test "granting and revoking a server takes effect" do
      membership = org_memberships(:contractor_in_acme)

      post grant_org_member_path(org_id: ACME, id: membership.id), params: {server_id: servers(:beta).id}

      assert_includes membership.reload.server_accesses.map(&:server_id), servers(:beta).id

      delete revoke_org_member_path(org_id: ACME, id: membership.id), params: {server_id: servers(:beta).id}

      assert_not_includes membership.reload.server_accesses.map(&:server_id), servers(:beta).id
    end

    # The server side is scoped through the org too. Scoping the membership and
    # not the server is how a grant ends up pairing this org's member with
    # another org's server — and with its PAT.
    test "a server from another org cannot be granted" do
      membership = org_memberships(:contractor_in_acme)

      assert_no_difference("Org::ServerAccess.count") do
        post grant_org_member_path(org_id: ACME, id: membership.id), params: {server_id: servers(:gamma).id}
      end
    end

    test "a membership from another org cannot be addressed" do
      foreign = org_memberships(:outsider_in_globex)

      delete org_member_path(org_id: ACME, id: foreign.id)

      assert_response :not_found
      assert Org::Membership.exists?(foreign.id)
    end

    # An org with no admin or owner is unreachable by anyone — membership is the
    # only source of access — while its servers keep being polled with live PATs.
    test "the last owner cannot be removed" do
      membership = org_memberships(:owner_in_acme)

      delete org_member_path(org_id: ACME, id: membership.id)

      assert Org::Membership.exists?(membership.id)
    end
  end
end
