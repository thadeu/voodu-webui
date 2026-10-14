# frozen_string_literal: true

# Components::Hep3::CountCard — the /hep3 "how many calls" tile: distinct SIP
# calls in the window (each call once), the NumberCard headline + sparkline.
#
# Near-real-time by polling ITS OWN frame (POLL_MS), not the page grid: the
# table next to it keeps its rows, scroll and live state untouched. The card
# root stays in the metrics-display grid (hide / order / resize from Settings);
# only the frame inside swaps, so a poll never moves the card out of place.
class Components::Hep3::CountCard < Components::Base
  POLL_MS = 10_000

  def initialize(data:, src:, metric:)
    @data = data
    @src = src
    @metric = metric
  end

  def view_template
    div(
      class: "relative min-w-0 flex flex-col",
      data: {
        metrics_display_target: "card",
        metric_key: @metric,
        controller: "polling",
        polling_interval_value: POLL_MS
      }
    ) do
      render Components::Hep3::CountFrame.new(data: @data, src: @src)

      resize_handle("left")
      resize_handle("right")
    end
  end

  private

  def resize_handle(edge)
    div(
      data: {action: "pointerdown->metrics-display#startResize", resize_edge: edge},
      aria: {hidden: "true"},
      title: "Drag to resize",
      class: tokens(
        "absolute top-0 bottom-0 w-1.5 cursor-col-resize hover:bg-voodu-accent/30 active:bg-voodu-accent/60 z-10 touch-none",
        (edge == "left") ? "left-0" : "right-0"
      )
    )
  end
end
