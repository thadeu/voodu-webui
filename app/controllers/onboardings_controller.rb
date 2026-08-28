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

    org = build_workspace(account_name, org_name)

    redirect_to org_root_path(org_id: org.short_id), notice: "Welcome. #{org.name} is ready."
  rescue ActiveRecord::RecordInvalid => e
    render Views::Onboardings::New.new(
      account_name: account_name, org_name: org_name, error: e.record.errors.full_messages.to_sentence
    ), status: :unprocessable_entity
  end

  private

  # One transaction: an account without an org is a dead end, and an org
  # without the owner membership is an org nobody can reach.
  def build_workspace(account_name, org_name)
    Account.transaction do
      account = Account.create!(name: account_name, owner: Current.user)
      org = account.orgs.create!(name: org_name)
      org.memberships.create!(user: Current.user, role: :owner, status: :active)

      org
    end
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
