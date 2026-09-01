# frozen_string_literal: true

# OnboardingsController — the one screen a person with no org can act on.
#
# Membership is the only source of access, so a first sign-in reaches nothing:
# no account, no org, no servers. This creates all three in one transaction —
# the account they own, their first org inside it, and the owner membership
# that actually grants the access. Skipping any of the three leaves them
# somewhere they cannot get out of.
#
# Not gated on a capability: the person has no role anywhere yet, so every
# capability check would deny. It is gated on having nowhere to go — an
# operator who already belongs somewhere is redirected out.
class OnboardingsController < ApplicationController
  skip_before_action :require_server!

  before_action :redirect_if_settled

  def new
    return render_invitation_needed unless entitlements.room_for_another_account?

    render Views::Onboardings::New.new(account_name: default_account_name, org_name: "")
  end

  def create
    account_name = params[:account_name].to_s.strip
    org_name = params[:org_name].to_s.strip

    if account_name.empty? || org_name.empty?
      return render(Views::Onboardings::New.new(
        account_name: account_name, org_name: org_name,
        error: "Both names are required."
      ), status: :unprocessable_entity)
    end

    # Kept as well as the check in `new`: a form is not a control. Somebody who
    # opened this page before the last account was created — or who posts
    # directly — must be refused here too.
    return render_invitation_needed unless entitlements.room_for_another_account?

    org = Account.provision!(owner: Current.user, account_name: account_name, org_name: org_name)

    redirect_to org_root_path(org_id: org.short_id), notice: "Welcome. #{org.name} is ready."
  rescue ActiveRecord::RecordInvalid => e
    render Views::Onboardings::New.new(
      account_name: account_name, org_name: org_name, error: e.record.errors.full_messages.to_sentence
    ), status: :unprocessable_entity
  end

  private

  # Shown instead of the setup form. See the view for why a form that cannot
  # succeed is worse than a page that explains itself.
  def render_invitation_needed
    render Views::Onboardings::InvitationNeeded.new, status: :forbidden
  end

  def redirect_if_settled
    return if Current.user.nil?
    return unless Current.user.active_orgs.exists?

    redirect_to root_path(org_id: nil, server_key: nil)
  end

  def default_account_name
    Current.user&.display_name.to_s.split("@").first.to_s.titleize.presence || "My account"
  end
end
