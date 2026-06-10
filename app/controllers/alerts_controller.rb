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
    data = AlertsPageData.new(current_island)

    if request.headers["Turbo-Frame"] == "alerts-live"
      render Views::Alerts::Frame.new(data: data), layout: false
    else
      render Views::Alerts::Index.new(**dashboard_context.merge(data: data))
    end
  end
end
