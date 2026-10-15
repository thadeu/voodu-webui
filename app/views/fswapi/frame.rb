# frozen_string_literal: true

# Views::Fswapi::Frame — the polled part of the FreeSWITCH page on its own:
# what a polling tick or a tab click swaps in.
class Views::Fswapi::Frame < Views::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    turbo_frame_tag(FswapiController::FRAME) do
      render Components::Fswapi::Body.new(data: @data)
    end
  end
end
