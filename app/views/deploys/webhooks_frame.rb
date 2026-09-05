# frozen_string_literal: true

# The frame body returned when Turbo refetches the deliveries table.
#
# WRAPPED IN THE FRAME TAG: Turbo looks for a `<turbo-frame>` with the same id
# in the response and swaps its contents. A bare fragment has none to find, so
# the panel renders "Content missing" and the real body flashes past on the way
# there.
class Views::Deploys::WebhooksFrame < Views::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    turbo_frame_tag(DeploysController::WEBHOOKS_FRAME) do
      render Components::Deploys::WebhooksBody.new(data: @data)
    end
  end
end
