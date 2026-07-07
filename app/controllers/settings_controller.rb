# frozen_string_literal: true

# SettingsController — per-server settings surface.
#
# Scope is PER-server: everything rendered here is about the server
# the operator's currently focused on (Server record + /system
# payload from that server's agent). Global webui prefs (refresh
# cadence, log buffer, appearance) are a separate concern that
# will land later in a server-LESS /settings/global page.
class SettingsController < ApplicationController
  def index
    render Views::Settings::Index.new(
      **dashboard_context.merge(
        system: ServerSystem.fetch(voodu_client, current_server),
        pats: ServerPats.fetch(voodu_client, current_server)
      )
    )
  end

  # revoke_pat — DELETE /pats/<id> on the agent. Invalidates the
  # PAT cache so the next Settings render shows the freshly-shrunk
  # list. Surfaces the controller's error verbatim in the flash so
  # auth/not-found/etc. are visible to the operator.
  def revoke_pat
    voodu_client.revoke_pat(params[:pat_id])
    ServerPats.invalidate(current_server)
    redirect_to settings_path, notice: "Token revoked."
  rescue Voodu::Client::Error => e
    redirect_to settings_path, alert: "Couldn't revoke token: #{e.message}"
  end

  # reconnect — immediately re-probes the agent. refresh! warms the
  # health cache with the result, so the topbar status pill reflects it
  # on the redirect render. Also invalidates ServerSystem so the next
  # Settings render shows fresh agent data.
  def reconnect
    ServerSystem.invalidate(current_server)
    new_status = ServerHealth.refresh!(current_server)

    notice =
      if new_status == :online
        "Reconnected — agent is online."
      else
        "Couldn't reach the agent. Check the endpoint + PAT, then try again."
      end
    redirect_to settings_path, notice: notice
  end
end
