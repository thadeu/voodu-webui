# frozen_string_literal: true

# Views::Activity::Frame — the frame body returned when Turbo refetches
# `activity-table`: a filter chip, a page link, or the activity_tick broadcast
# after the poller lands a digest.
#
# Mirrors the frame content in Views::Activity::Index exactly, so the swap does
# not flicker and the operator keeps the filters they were looking at.
class Views::Activity::Frame < Views::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    turbo_frame_tag(ActivityController::FRAME) do
      render Components::Activity::Body.new(data: @data)
    end
  end
end
