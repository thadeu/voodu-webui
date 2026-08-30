# frozen_string_literal: true

# Turning on Clowk sign-in from Settings.
#
# The second thing this installation can buy. An operator running the free tier
# behind a VPN decides they want real per-person identity, pays for a Clowk
# instance, pastes its publishable key here, and sign-in starts working on the
# next request.
#
# Two things make this safe to offer, and neither is optional:
#
#   1. NOTHING IS MOVED YET. Anonymous mode runs as one local operator row, and
#      a Clowk sign-in provisions by subject — so the first real sign-in would
#      otherwise create a NEW user with no membership and strand every server
#      and PAT in an org nobody could reach. This only RECORDS which address may
#      claim the workspace; the handover happens in AuthMigrationsController,
#      after that person has actually signed in. Doing it here instead would
#      mean a wrong publishable key left the operator renamed AND locked out.
#
#   2. THE ENVIRONMENT STILL OVERRIDES THIS. A wrong key here would lock the
#      operator out of their own dashboard; restarting with CLOWK_ENABLED=0
#      always gets them back. See AuthSettings.
class AuthConfigsController < ApplicationController
  skip_before_action :require_server!

  authorize :manage_account

  def create
    return refuse(env_pinned_message) if AuthSettings.env_decides?

    email = params[:owner_email].to_s.strip.downcase
    return refuse("Enter the address that will sign in and own this workspace.") if email.blank?

    conflict = User.where(email: email).where.not(id: adoptable_operator&.id).first
    return refuse("#{email} already has an account here — sign in as them instead.") if conflict

    activate!(email)
  rescue ActiveRecord::RecordInvalid => e
    refuse(e.record.errors.full_messages.to_sentence)
  end

  # The safety valve, while there is still a session to use it from.
  def destroy
    AuthConfig.delete_all

    redirect_to return_to_path(installation_path),
      notice: "Clowk sign-in turned off. This installation is anonymous again — " \
              "make sure a VPN or access proxy is in front of it."
  end

  private

  def activate!(email)
    AuthConfig.create!(
      publishable_key: params[:publishable_key].to_s.strip,
      subdomain_url: params[:subdomain_url].to_s.strip.presence,
      secret_key: params[:secret_key].to_s.strip.presence,
      pending_owner_email: (email if adoptable_operator),
      configured_by: Current.user
    )

    AuthSettings.apply!

    redirect_to return_to_path(installation_path),
      notice: "Sign-in is on. Your next request will ask you to authenticate — sign in " \
              "as #{email} and you will be offered this workspace. Nothing has moved yet."
  end

  # The anonymous operator, when that is who is running this. Nil once the
  # install already has real identities, and then there is nothing to hand over.
  def adoptable_operator
    return @adoptable_operator if defined?(@adoptable_operator)

    @adoptable_operator = User.find_by(email: User::LOCAL_OPERATOR_EMAIL)
  end

  def env_pinned_message
    "Sign-in is configured by environment variables on this installation, which " \
      "take precedence. Change CLOWK_ENABLED / CLOWK_PUBLISHABLE_KEY there instead."
  end

  def refuse(message) = redirect_to(return_to_path(installation_path), alert: message)
end
