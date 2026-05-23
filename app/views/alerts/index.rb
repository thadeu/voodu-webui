# frozen_string_literal: true

class Views::Alerts::Index < Views::Base
  def initialize(current_path:, islands: [], current_island: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, islands: @islands, current_island: @current_island
    ) do
      render Views::Shared::MilestonePlaceholder.new(
        title: "Alerts",
        blurb: "Probe failures, reconcile errors, restart bursts. PAT plane doesn't surface alerts yet — sidebar badge is mocked for now.",
        milestone: "future"
      )
    end
  end
end
