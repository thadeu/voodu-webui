# frozen_string_literal: true

# Views::Alerts::Frame — the turbo-frame body returned when Turbo
# refetches the `alerts-live` frame (the `alerts_tick` broadcast
# after a fire/resolve transition, or a tab navigation).
#
# Mirrors the frame content in Views::Alerts::Index exactly — same
# wrapper, same LiveBody, same active_tab (read from ?tab= on the
# refetched src) — so the swap doesn't visually flicker and the
# operator stays on whichever tab they were viewing.
class Views::Alerts::Frame < Views::Base
  def initialize(data:, active_tab: :active)
    @data = data
    @active_tab = active_tab
  end

  def view_template
    turbo_frame_tag("alerts-live") do
      div(class: "flex flex-col gap-4 vmd:gap-5") do
        render Components::Alerts::LiveBody.new(data: @data, active_tab: @active_tab)
      end
    end
  end
end
