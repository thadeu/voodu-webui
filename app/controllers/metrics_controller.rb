# frozen_string_literal: true

# MetricsController — host + per-pod resource usage cards.
#
# In M4 the sparkline data is synthetic per render — the controller
# /stats endpoint returns a single instantaneous snapshot, not a
# series. M5+ persists periodic snapshots to SQLite so sparklines
# show real history.
class MetricsController < ApplicationController
  def index
    @stats, @error = fetch_stats
    render Views::Metrics::Index.new(**dashboard_context.merge(stats: @stats, error: @error))
  end

  private

  def fetch_stats
    return [nil, nil] if voodu_client.nil?

    [voodu_client.stats, nil]
  rescue Voodu::Client::Error => e
    [nil, e]
  end
end
