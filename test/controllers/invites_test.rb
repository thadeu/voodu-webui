# frozen_string_literal: true

require "test_helper"

# An invitation is a membership row with status: invited, and the link is that
# row's signed id. Accepting therefore identifies ONE exact invitation — not
# "whoever signs in with the address we guessed", which is how an invitation
# gets handed to the wrong person.
class InvitesTest < ActionDispatch::IntegrationTest
  setup { @invitation = org_memberships(:invitee_in_acme) }

  test "the invitee accepts and lands inside the org" do
    sign_out
    sign_in_as(email: users(:invitee).email, name: "Invitee")

    get invite_path(@invitation.invite_token)

    assert @invitation.reload.active?
    assert_redirected_to org_root_path(org_id: orgs(:acme).short_id)
  end

  # The core attack. Note the ordering it also pins: a stranger must not be told
  # "you are already a member", because that confirms the person they are
  # impersonating is in this org.
  test "someone else's invitation is refused, not transferred" do
    sign_out
    sign_in_as(email: users(:outsider).email, name: "Outsider")

    get invite_path(@invitation.invite_token)

    assert @invitation.reload.invited?, "the invitation must stay unclaimed"
    assert_equal users(:invitee).id, @invitation.user_id
    assert_response :redirect
    assert_not_includes flash[:alert].to_s, orgs(:acme).name
  end

  test "a tampered token is refused" do
    sign_out
    sign_in_as(email: users(:invitee).email)

    get invite_path("#{@invitation.invite_token}x")

    assert @invitation.reload.invited?
  end

  test "an expired token is refused" do
    token = @invitation.invite_token
    sign_out
    sign_in_as(email: users(:invitee).email)

    travel(Org::Membership::INVITE_MAX_AGE + 1.day) do
      get invite_path(token)

      assert @invitation.reload.invited?
    end
  end

  test "an anonymous visitor is sent through sign-in first" do
    sign_out

    get invite_path(@invitation.invite_token)

    assert_response :redirect
    assert_match %r{/sign_in}, response.location
    assert @invitation.reload.invited?
  end

  # Accepting joins the org. It does not hand over any server: a member reaches
  # only what an admin grants, and acceptance grants nothing.
  test "accepting as a member grants no servers" do
    sign_out
    sign_in_as(email: users(:invitee).email)

    get invite_path(@invitation.invite_token)

    assert_empty @invitation.reload.server_accesses

    get server_root_path(org_id: orgs(:acme).short_id, server_key: servers(:alpha).key)

    assert_not_equal 200, response.status
  end
end
