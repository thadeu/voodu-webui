# frozen_string_literal: true

# Views::Logs::Index — multi-source log tail (`/logs`).
# Streams from every known pod profile.
class Views::Logs::Index < Views::Base
  def initialize(current_path:, islands: [], current_island: nil, updated_at: nil, pods: [])
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @updated_at     = updated_at
    @pods           = pods
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, islands: @islands,
      current_island: @current_island, updated_at: @updated_at,
      breadcrumb: (@current_island && overview_crumbs(
        { label: "Logs", href: logs_analytics_path(tenant_key: @current_island.key) },
        { label: "Follow" }
      ))
    ) do
      if @current_island.nil?
        render Components::UI::NoIslandState.new
      else
        render Components::Logs::Page.new(pod_name: nil, pods: @pods)
      end
    end
  end
end
