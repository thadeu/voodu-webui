# frozen_string_literal: true

class Views::Settings::Index < Views::Base
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
        title: "Settings", milestone: "M3 placeholder",
        blurb: "Per-island configuration: PAT rotation, refresh cadence, alerts."
      )
    end
  end
end
