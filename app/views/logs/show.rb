# frozen_string_literal: true

# Views::Logs::Show — pod-scoped log tail (`/logs/:name`). Linked
# from PodDetailPage's "View logs" button. Toolbar shows the pod chip
# with × that links back to /logs (multi-source).
class Views::Logs::Show < Views::Base
  # drawer: true → embedded render path used by Components::UI::Drawer.
  # Skips the Dashboard chrome (sidebar/topbar) so the drawer's body
  # gets just the log viewer surface.
  def initialize(current_path:, islands: [], current_island: nil, updated_at: nil, pod_name:, drawer: false)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @updated_at     = updated_at
    @pod_name       = pod_name
    @drawer         = drawer
  end

  def view_template
    if @drawer
      render Components::Logs::Page.new(pod_name: @pod_name, drawer: true)
    else
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
end
