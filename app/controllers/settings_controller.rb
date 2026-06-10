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

  # reconnect — immediately re-probes the agent. refresh! warms the
  # health cache with the result, so the topbar status pill reflects it
  # on the redirect render. Also invalidates IslandSystem so the next
  # Settings render shows fresh agent data.
  def reconnect
    IslandSystem.invalidate(current_island)
    new_status = IslandHealth.refresh!(current_island)

    notice =
      if new_status == :online
        "Reconnected — agent is online."
      else
        "Couldn't reach the agent. Check the endpoint + PAT, then try again."
      end
    redirect_to settings_path, notice: notice
  end

  # update_preferences — POST endpoint for the operator's global
  # display prefs (today: timezone only; tomorrow: refresh cadence,
  # theme, etc.).
  #
  # Timezone validation routes through WebTime.valid_zone? so an
  # IANA-name string that ActiveSupport recognises is the bar.
  # Blank value clears the preference back to UTC (default).
  # Garbage input bounces with a flash error, no DB write.
  def update_preferences
    tz = params[:timezone].to_s.strip

    if tz.empty?
      Setting.set(Setting::KEY_TIMEZONE, "")
      WebTime.clear_request_cache
      return redirect_to settings_path, notice: "Timezone cleared — using UTC."
    end

    unless WebTime.valid_zone?(tz)
      return redirect_to settings_path, alert: "Unknown timezone '#{tz}'. Use an IANA name like America/Sao_Paulo or UTC."
    end

    Setting.set(Setting::KEY_TIMEZONE, tz)
    WebTime.clear_request_cache
    redirect_to settings_path, notice: "Timezone set to #{tz}."
  end
end
