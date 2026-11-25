# frozen_string_literal: true

# OrgMailer — an invitation to an org, with the same signed link the members
# screen offers to copy. The link expires with the invitation.
class OrgMailer < ApplicationMailer
  def invitation(membership)
    @org = membership.org
    @inviter = membership.invited_by&.name.presence || "Someone"
    @url = invite_url(invite_token: membership.invite_token, org_id: nil)

    mail(to: membership.user.email, subject: "#{@inviter} invited you to #{@org.name} on Voodu")
  end
end
