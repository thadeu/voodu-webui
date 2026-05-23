# frozen_string_literal: true

# Views::Logs::Show — pod-scoped log tail (`/logs/:name`). Linked
# from PodDetailPage's "View logs" button. Toolbar shows the pod chip
# with × that links back to /logs (multi-source).
class Views::Logs::Show < Views::Base
  def initialize(current_path:, islands: [], current_island: nil, updated_at: nil, pod_name:)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @updated_at     = updated_at
    @pod_name       = pod_name
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, islands: @islands,
      current_island: @current_island, updated_at: @updated_at
    ) do
      if @current_island.nil?
        render Components::UI::NoIslandState.new
      else
        render Components::Logs::Page.new(pod_name: @pod_name)
      end
    end
  end
end
