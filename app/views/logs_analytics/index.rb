# frozen_string_literal: true

# Views::LogsAnalytics::Index — full page for /logs/analytics. Renders
# the Dashboard chrome + the LogAnalytics::Page (filter bar + results
# table inline). The results table is wrapped in a Turbo Frame so the
# filter bar can re-query it in place; see LogsAnalyticsController#index.
class Views::LogsAnalytics::Index < Views::Base
  def initialize(current_path:, islands: [], current_island: nil, updated_at: nil, pods: [], data: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @updated_at     = updated_at
    @pods           = pods
    @data           = data
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, islands: @islands,
      current_island: @current_island, updated_at: @updated_at
    ) do
      if @current_island.nil? || @data.nil?
        render Components::UI::NoIslandState.new
      else
        render Components::LogAnalytics::Page.new(data: @data, pods: @pods)
      end
    end
  end
end
