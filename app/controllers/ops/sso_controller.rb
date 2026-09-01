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
class Ops::SsoController < ApplicationController
  skip_before_action :require_server!

  authorize_anywhere :manage_account

  before_action :refuse_on_hosted

  def index
    render Views::Ops::Sso::Index.new(current_path: request.path, servers: sidebar_servers)
  end

  def create
    return bounce(env_pinned_message) if AuthSettings.env_decides?

    email = params[:owner_email].to_s.strip.downcase
    return bounce("Enter the address that will sign in and own this workspace.") if email.blank?

    # No refusal for an address that already exists here, and that removal is
    # deliberate. It read as a safety check and was really a guess about intent:
    # turning sign-in off and on again for the same person is the SAME
    # configuration, but by then that person had a real user row — created by
    # the sign-in the operator had just performed — so re-enabling SSO for
    # themselves was refused with "sign in as them instead", from a screen that
    # offered no way to do anything else.
    #
    # Nothing was protected by it. The handover is gated where it always was:
    # pending_owner_email is only recorded when there is an anonymous workspace
    # to hand over, Ops::SsoConfig#claimable_by? demands a PROVEN address that
    # matches, and the person has to confirm on a screen of their own. Naming an
    # address here has never been enough to move anything.
    activate!(email)
  rescue ActiveRecord::RecordInvalid => e
    bounce(e.record.errors.full_messages.to_sentence)
  end

  # The safety valve, while there is still a session to use it from.
  #
  # Refused when the environment decides, which `create` has always checked and
  # this had not. On a host that sets CLOWK_ENABLED the deletion would not even
  # change sign-in — the env wins on the next resolve — so all it could do is
  # destroy stored configuration for no effect. On a multi-tenant installation
  # that is an unguarded destructive endpoint on installation-wide config.
  def destroy
    return bounce(env_pinned_message) if AuthSettings.env_decides?

    Ops::SsoConfig.delete_all

    redirect_to return_to_path(ops_sso_path),
      notice: "Clowk sign-in turned off. This installation is anonymous again — " \
              "make sure a VPN or access proxy is in front of it."
  end

  private

  # Not this customer's question. On the hosted service the installation is
  # ours, and who proves identity is decided once, for every tenant at the same
  # time — a screen offering to change it would be offering something it cannot
  # do, and `destroy` would be a tenant turning sign-in off for everybody.
  #
  # Applied to every action rather than to `index`, because hiding a screen
  # whose POST still answers is not hiding it.
  def refuse_on_hosted
    return unless Current.unlimited?

    redirect_to root_path(org_id: nil, server_key: nil)
  end

  def activate!(email)
    Ops::SsoConfig.create!(
      # Named rather than assumed: Clowk is the only provider today, and the
      # column exists so the second one does not need a migration.
      provider: "clowk",
      publishable_key: params[:publishable_key].to_s.strip,
      subdomain_url: params[:subdomain_url].to_s.strip.presence,
      secret_key: params[:secret_key].to_s.strip.presence,
      pending_owner_email: (email if adoptable_operator),
      configured_by: Current.user
    )

    # Nothing to apply here any more. Middleware::ClowkCredentials resolves the
    # instance at the top of every request, so the row just written governs the
    # next one — the old AuthSettings.apply! reached into the gem's process
    # configuration from inside this action to get the same effect.
    redirect_to return_to_path(ops_sso_path), notice: activation_notice(email)
  end

  # Says what will actually happen, and the two cases differ on one thing only:
  # whether there is an anonymous workspace waiting to be claimed. Promising a
  # handover on an installation that already runs on real identities would be
  # describing a step that never comes — which is what re-enabling sign-in after
  # a migration does.
  def activation_notice(email)
    if adoptable_operator.nil?
      return "Sign-in is on. Your next request will ask you to authenticate — sign in as #{email}."
    end

    "Sign-in is on. Your next request will ask you to authenticate — sign in as #{email} " \
      "and you will be offered this workspace. Nothing has moved yet."
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

  # NOT `refuse` — that is Authorization#refuse(capability), and defining it
  # here overrode it: a denied authorization redirected to this very page, which
  # denied again, until the browser gave up.
  def bounce(message) = redirect_to(return_to_path(ops_sso_path), alert: message)
end
