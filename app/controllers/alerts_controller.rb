# frozen_string_literal: true

# AlertsController — the /alerts page: firing episodes, the rules
# table, and resolved history, all read from the primary DB (no
# controller HTTP on the render path).
#
# Dual-mode like MetricsController: a Turbo-Frame request (the
# `alerts_tick` broadcast triggers `frame.reload()` on the
# `alerts-live` frame) re-renders ONLY the frame body with
# layout: false, so live updates skip the dashboard chrome.
class AlertsController < ApplicationController
  def index
    data = AlertsPageData.new(current_org, current_island, history_filter: history_filter)
    tab = active_tab

    if request.headers["Turbo-Frame"] == "alerts-live"
      render Views::Alerts::Frame.new(data: data, active_tab: tab), layout: false
    else
      render Views::Alerts::Index.new(**dashboard_context.merge(data: data, active_tab: tab))
    end
  end

  private

  # active_tab — which panel to render: active (firing) | rules |
  # history. Defaults to active; an unknown ?tab= falls back rather
  # than 404ing a bookmarked URL.
  TABS = %w[active rules destinations history].freeze

  def active_tab
    t = params[:tab].to_s
    TABS.include?(t) ? t.to_sym : :active
  end

  def history_filter
    AlertHistoryFilter.new(params.permit(:range, :from, :until).to_h)
  end
end
