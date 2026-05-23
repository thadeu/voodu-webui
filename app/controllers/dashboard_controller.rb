# frozen_string_literal: true

# DashboardController — "/" landing.
#
# The Overview screen does the heaviest data assembly in the app:
# it asks the PAT plane for /stats + /pods, then OverviewData prepares
# the bundle (decorating with synthetic series + per-pod mocks where
# the API doesn't supply data yet).
#
# Caching contract (see OverviewData::CACHE_TTL):
#   - First hit per island → fetches both /stats and /pods, caches.
#   - Subsequent hits within TTL (incl. filter switches) → served
#     from Rails.cache; no network round-trip.
#   - `?refresh=1` (the "Refresh all" button) → bypasses + repopulates.
class DashboardController < ApplicationController
  def index
    @data = OverviewData.new(
      voodu_client, current_island,
      force_refresh: params[:refresh].present?
    )

    render Views::Dashboard::Index.new(
      **dashboard_context.merge(
        data: @data,
        active_tab: tab_param,
        updated_at: @data.updated_at
      )
    )
  end

  private

  def tab_param
    case params[:status]
    when "running"    then :running
    when "restarting" then :restarting
    when "stopped"    then :stopped
    else                   :all
    end
  end
end
