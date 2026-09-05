# frozen_string_literal: true

# The frame body returned when Turbo refetches the deployments table: a filter
# change, a page link, or the polling tick.
#
# WRAPPED IN THE FRAME TAG, and that is the whole reason this view exists
# rather than the controller rendering the body component directly. Turbo looks
# for a `<turbo-frame>` with the SAME ID in the response and swaps its
# contents; a bare fragment has no frame to find, so the panel renders
# "Content missing" and the real body flashes past on the way there.
#
# Mirrors the frame content in Views::Deploys::Deployments exactly, so the swap
# does not flicker and the operator keeps the filters they were looking at.
class Views::Deploys::DeploymentsFrame < Views::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    turbo_frame_tag(DeploysController::FRAME) do
      render Components::Deploys::DeploymentsBody.new(data: @data)
    end
  end
end
