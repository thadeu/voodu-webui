# frozen_string_literal: true

# InvitesController — the link an admin copies out of the members screen lands
# here.
#
# The token is the membership's signed id, so accepting identifies ONE exact
# invitation. It is not an address match: "whoever signs in with the address we
# guessed" is how an invitation gets handed to the wrong person.
class InvitesController < ApplicationController
  # This action needs Current.user resolved to know whose invitation it is
  # holding, so it keeps the authentication chain and skips only the parts that
  # assume a tenant — an invitee has no membership in this org yet, by
  # definition.
  skip_before_action :require_server!

  def show
    membership = Org::Membership.find_invited(params[:invite_token])

    return refuse("That invitation link is invalid or has expired.") if membership.nil?

    # Whose invitation this is comes FIRST. Answering "you are already a member"
    # to a stranger would confirm that the person they are impersonating is in
    # that org — so the ownership check runs before any check of state.
    unless membership.user_id == Current.user&.id
      return refuse("That invitation was sent to someone else. Sign in with that address to accept it.")
    end

    membership.update!(status: :active) unless membership.active?

    redirect_to org_root_path(org_id: membership.org.short_id),
      notice: "You're in — welcome to #{membership.org.name}."
  end

  private

  def refuse(message)
    redirect_to root_path(org_id: nil, server_key: nil), alert: message
  end
end
