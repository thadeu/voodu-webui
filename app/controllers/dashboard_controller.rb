# frozen_string_literal: true

# DashboardController — "/" landing.
#
# The Overview screen does the heaviest data assembly in the app:
# it asks the PAT plane for /stats + /pods, then OverviewData prepares
# the bundle (decorating with synthetic series + per-pod mocks where
# the API doesn't supply data yet).
#
# Caching contract (see OverviewData::CACHE_TTL):
#   - First hit per server → fetches both /stats and /pods, caches.
#   - Subsequent hits within TTL (incl. filter switches) → served
#     from Rails.cache; no network round-trip.
#   - `?refresh=1` (the "Refresh all" button) → bypasses + repopulates.
class DashboardController < ApplicationController
  # Bare-root entry. No server_key in the URL — bounce the operator
  # to the first available server, or to /servers/new if they haven't
  # registered any yet. Keeps `/` a meaningful URL without having to
  # encode "no server context" all over the dashboard.
  skip_before_action :require_server!, only: [:redirect_to_default, :org_root]

  def redirect_to_default
    # reachable_servers, not Server.order(:name).first: "/" used to land on the
    # alphabetically-first server in the INSTALL, which under multi-tenancy is
    # someone else's. Every require_server! bounce comes through here too.
    if (server = reachable_servers.order(:name).first)
      redirect_to server_root_path(org_id: server.org.short_id, server_key: server.key)
    elsif administrable_orgs.exists?
      # Only for someone who may actually register one. Sending a plain member
      # here meant the form refused them and bounced them back to `/`, which
      # sent them to the form again — a redirect loop the browser eventually
      # gave up on.
      redirect_to new_server_path(org_id: administrable_orgs.order(:name).first.short_id)
    elsif Current.user&.active_orgs&.exists?
      redirect_to all_servers_path
    else
      # No org at all. Before offering to build a new workspace, check whether
      # there is an EXISTING one waiting for this person — an installation that
      # ran anonymously and named them when it turned sign-in on. Sending them
      # to onboarding instead would have them build a second workspace beside
      # the one they came to claim.
      return redirect_to(auth_migration_path) if claimable_migration?

      # A first sign-in, or someone whose last membership was removed.
      # Onboarding is the only screen they can act on.
      redirect_to new_onboarding_path
    end
  end

  def claimable_migration?
    SsoConfiguration.current&.claimable_by?(Current.user)
  rescue ActiveRecord::ActiveRecordError
    false
  end

  # org_root — /<org8>/ (org in the URL, no server). Lands on the org's first
  # server overview, or the add-server form when the org has no servers yet.
  def org_root
    return redirect_to(root_path(org_id: nil, server_key: nil)) if current_org.nil?

    if (server = authorized_servers.order(:name).first)
      redirect_to server_root_path(org_id: current_org.short_id, server_key: server.key)
    elsif allowed_in?(current_org, :manage_servers)
      redirect_to new_server_path(server_key: nil)
    else
      # A member with no granted server in this org: the registry renders and
      # explains itself; the form would just refuse them.
      redirect_to servers_path(server_key: nil)
    end
  end

  def index
    @data = OverviewData.new(
      voodu_client, current_server,
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
        recent_alerts: current_org.alert_rules.includes(:server).order(created_at: :desc).limit(5).to_a,
        recent_dashboards: current_org.metric_dashboards.order(created_at: :desc).limit(5).to_a,
        recent_events: current_org.alert_events.includes(:server).order(started_at: :desc).limit(6).to_a
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
