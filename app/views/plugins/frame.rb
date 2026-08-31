# frozen_string_literal: true

# Views::Plugins::Frame — the grid on its own, for the polling tick.
#
# The Index hosts this inside a turbo-frame that refetches on a timer, so an
# install still running resolves itself without the operator reloading. Only
# the grid is in here; the chrome and the install form are siblings of the
# frame, so a tick never steals focus from a half-typed repository name.
class Views::Plugins::Frame < Views::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    turbo_frame_tag(PluginsController::FRAME) do
      render Components::Plugins::Grid.new(data: @data)
    end
  end
end
