# frozen_string_literal: true

# Views::Alerts::Frame — the turbo-frame body returned when Turbo
# refetches the `alerts-live` frame (the `alerts_tick` broadcast
# after a fire/resolve transition).
#
# Mirrors the frame content in Views::Alerts::Index exactly — same
# wrapper, same LiveBody — so the swap doesn't visually flicker.
class Views::Alerts::Frame < Views::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    turbo_frame_tag("alerts-live") do
      div(class: "flex flex-col gap-4 vmd:gap-5") do
        render Components::Alerts::LiveBody.new(data: @data)
      end
    end
  end
end
