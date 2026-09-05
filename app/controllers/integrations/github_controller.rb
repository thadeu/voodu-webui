# frozen_string_literal: true

# Integrations::GithubController — connecting a customer's GitHub to a server.
#
# Two actions, and they live at different levels on purpose:
#
#   connect   /:org_id/:server_key/integrations/github/connect
#             Server-scoped, because "which server deploys from GitHub" is a
#             per-server decision. The INSTALLATION is per GitHub account —
#             GitHub allows one per App — but the choice of which box uses it
#             is made while looking at that box.
#
#   callback  /integrations/github/callback
#             Top-level, because GitHub redirects here knowing nothing about
#             our orgs. The signed `state` carries that, and is the only reason
#             this is safe without a URL that names the org.
module Integrations
  class GithubController < ApplicationController
    # The callback carries no :server_key — GitHub redirects there knowing
    # nothing about our URLs. The server it belongs to comes out of the state.
    skip_before_action :require_server!, only: [:callback]

    authorize :manage_deploys, only: [:connect]

    # connect — send the operator to GitHub to authorize the App.
    #
    # The state is minted here, before the redirect, and is what the callback
    # checks on the way back. Without it the callback would trust a query
    # parameter typed by whoever is logged in.
    def connect
      return reject("Deploys from GitHub are not part of this plan.") unless entitlements.deploy_plane?

      settings = GithubSettings.current

      unless settings.configured?
        redirect_to server_root_path(org_id: current_org.short_id, server_key: current_server.key),
          alert: "This installation has no GitHub App configured yet."

        return
      end

      state = Integration::Github::State.generate(
        org: current_org, server: current_server, user: Current.user
      )

      # allow_other_host because this deliberately leaves for github.com — the
      # default refusal exists to catch open redirects built from user input,
      # and this URL is built from our own configuration.
      redirect_to "#{settings.install_url}?state=#{CGI.escape(state)}", allow_other_host: true
    end

    # callback — GitHub sends the operator back after they authorise.
    #
    # No `authorize` filter: authorisation here comes from the STATE, not from
    # the URL, because the URL cannot name an org. The state names the org, the
    # server and the person, and the checks below confirm all three still hold.
    def callback
      payload = Integration::Github::State.verify(params[:state])

      # A callback we did not start. The most likely cause is a stale link, and
      # the most dangerous one is somebody pasting an installation id they do
      # not own — treated identically, because we cannot tell them apart and
      # both mean "do not bind this".
      return reject("That GitHub link has expired. Start again from the server.") if payload.nil?

      # `request` means the person asked an org owner to approve the App and
      # nothing was installed. Not an error, and not something to bind.
      if params[:setup_action] == "request"
        return reject("GitHub is waiting for an owner of that account to approve the app.")
      end

      installation_id = params[:installation_id].to_s.strip

      return reject("GitHub did not send an installation id.") if installation_id.blank?

      org = authorized_org(payload)

      # The state was valid, but the person's access changed since — they were
      # removed from the org, or lost the capability, between leaving and
      # returning. The signature proves who started it; it does not prove they
      # may still finish it.
      return reject("You no longer have access to that organisation.") if org.nil?

      server = org.servers.find_by(id: payload.server_id)

      return reject("That server no longer exists.") if server.nil?

      # Re-checked on the way back, not only on the way out: the plan can lapse
      # while the operator is on GitHub's screen, and binding an installation
      # this installation may no longer use would leave a connection nothing
      # can fire.
      unless Entitlements.for(org.account).deploy_plane?
        return reject("Deploys from GitHub are not part of this plan.")
      end

      integration = record_installation(org, installation_id)

      redirect_to server_root_path(org_id: org.short_id, server_key: server.key),
        notice: "GitHub connected#{" as #{integration.account_login}" if integration.account_login.present?}."
    end

    private

    # authorized_org — the org from the state, but only if this person may
    # still act on it.
    #
    # Re-derived from the CURRENT user rather than trusted from the payload:
    # the state says who STARTED, and the session says who is here now. Signing
    # the user id lets us notice they differ; it does not make the signed one
    # authoritative.
    #
    # The membership is looked up directly instead of through `allowed?`, and
    # that is forced rather than chosen: `allowed?` reads Current.role, which
    # comes from the `:org_id` segment — and this route has none, because
    # GitHub redirects here knowing nothing about our orgs. Asking a helper
    # that resolves to nil here would deny everything, including the legitimate
    # return.
    def authorized_org(payload)
      return nil unless Current.user&.id == payload.user_id

      org = Current.user.active_orgs.find_by(id: payload.org_id)

      return nil if org.nil?

      membership = Current.user.membership_in(org)

      return nil unless Permissions.allow?(membership&.role, :manage_deploys)

      org
    end

    def record_installation(org, installation_id)
      integration = Integration::Record.find_or_initialize_by(
        org: org, provider: "github", external_id: installation_id
      )

      integration.name ||= "GitHub"
      integration.status = "active"
      integration.account_login = account_login_for(installation_id) || integration.account_login

      integration.save!
      integration
    end

    # account_login_for — whose GitHub account this is, for the screen.
    #
    # Best-effort: the id alone is enough to deploy, and failing the whole
    # connection because a cosmetic lookup timed out would turn a working
    # integration into an error the operator cannot act on.
    def account_login_for(installation_id)
      Integration::Github::Client.new.installation(installation_id).dig("account", "login")
    rescue Integration::Github::Client::Error, Integration::Github::AppJwt::MissingCredentials => e
      Rails.logger.warn("[github] could not read installation #{installation_id}: #{e.class}")
      nil
    end

    # reject — every failure lands on a page the operator can act from, with a
    # sentence saying what to do. A bare 400 here would leave somebody staring
    # at a blank page after granting an app access to their code.
    def reject(message)
      # org_id/server_key explicitly nil: default_url_options would otherwise
      # re-inject the segments of the request we are leaving, producing a
      # server-scoped URL for a page that has no server.
      redirect_to all_servers_path(org_id: nil, server_key: nil), alert: message
    end
  end
end
