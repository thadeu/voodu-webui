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
  # Bare-root entry. No tenant_key in the URL — bounce the operator
  # to the first available island, or to /islands/new if they haven't
  # registered any yet. Keeps `/` a meaningful URL without having to
  # encode "no island context" all over the dashboard.
  skip_before_action :require_tenant!, only: [:redirect_to_default, :org_root]

  def redirect_to_default
    if (island = Island.order(:name).first)
      redirect_to tenant_root_path(org_id: island.org.short_id, tenant_key: island.key)
    else
      redirect_to new_island_path
    end
  end

  # org_root — /<org8>/ (org in the URL, no server). Lands on the org's first
  # server overview, or the add-server form when the org has no servers yet.
  def org_root
    return redirect_to(root_path(org_id: nil, tenant_key: nil)) if current_org.nil?

    if (island = current_org.islands.order(:name).first)
      redirect_to tenant_root_path(org_id: current_org.short_id, tenant_key: island.key)
    else
      redirect_to new_island_path
    end
  end

  def index
    @data = OverviewData.new(
      voodu_client, current_island,
      force_refresh: params[:refresh].present?
    )

    render Views::Dashboard::Index.new(
      **dashboard_context.merge(
        data: @data,
        active_tab: tab_param,
        updated_at: @data.updated_at,
        # Org-level summaries (M2/M3), surfaced on every server's Overview:
        # recently CONFIGURED alert rules + dashboards, and recent alert
        # EPISODES (what actually fired) across the whole org.
        recent_alerts: current_org.alert_rules.includes(:island).order(created_at: :desc).limit(5).to_a,
        recent_dashboards: current_org.metric_dashboards.order(created_at: :desc).limit(5).to_a,
        recent_events: current_org.alert_events.includes(:island).order(started_at: :desc).limit(6).to_a
      )
    )
  end

  private

  def tab_param
    case params[:status]
    when "running" then :running
    when "restarting" then :restarting
    when "stopped" then :stopped
    else :all
    end
  end
end
