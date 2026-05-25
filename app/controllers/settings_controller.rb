# frozen_string_literal: true

# SettingsController — per-server settings surface.
#
# Scope is PER-island: everything rendered here is about the server
# the operator's currently focused on (Island record + /system
# payload from that island's agent). Global webui prefs (refresh
# cadence, log buffer, appearance) are a separate concern that
# will land later in a tenant-LESS /settings/global page.
class SettingsController < ApplicationController
  def index
    render Views::Settings::Index.new(
      **dashboard_context.merge(
        system: IslandSystem.fetch(voodu_client, current_island),
        pats:   IslandPats.fetch(voodu_client, current_island)
      )
    )
  end

  # revoke_pat — DELETE /pats/<id> on the agent. Invalidates the
  # PAT cache so the next Settings render shows the freshly-shrunk
  # list. Surfaces the controller's error verbatim in the flash so
  # auth/not-found/etc. are visible to the operator.
  def revoke_pat
    voodu_client.revoke_pat(params[:pat_id])
    IslandPats.invalidate(current_island)
    redirect_to settings_path, notice: "Token revoked."
  rescue Voodu::Client::Error => e
    redirect_to settings_path, alert: "Couldn't revoke token: #{e.message}"
  end

  # reconnect — drops the cached health status + immediately
  # re-probes the agent. Topbar status pill flips within the
  # same response cycle (status_for re-populates the cache as a
  # side effect). Also invalidates IslandSystem so the next
  # Settings render shows fresh agent data.
  def reconnect
    IslandHealth.invalidate(current_island)
    IslandSystem.invalidate(current_island)
    new_status = IslandHealth.status_for(current_island)

    notice =
      if new_status == :online
        "Reconnected — agent is online."
      else
        "Couldn't reach the agent. Check the endpoint + PAT, then try again."
      end
    redirect_to settings_path, notice: notice
  end
end
