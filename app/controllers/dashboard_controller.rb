# frozen_string_literal: true

# DashboardController — "/" landing. In M4 it shows the operational
# overview: host stats summary + pod counts + sparklines per island.
class DashboardController < ApplicationController
  def index
    @stats, @pods, @error = fetch_overview
    render Views::Dashboard::Index.new(
      **dashboard_context.merge(stats: @stats, pods: @pods, error: @error)
    )
  end

  private

  def fetch_overview
    return [nil, [], nil] if voodu_client.nil?

    [voodu_client.stats, voodu_client.pods["pods"] || [], nil]
  rescue Voodu::Client::Error => e
    [nil, [], e]
  end
end
