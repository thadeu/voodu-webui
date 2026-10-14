# frozen_string_literal: true

# Components::Hep3::CountFrame — the polled body of the /hep3 count card. The
# page renders it inline (first paint has the number); Hep3Controller#count
# renders it alone, and Turbo swaps just the frame. `src` is only set on the
# page render — the frame keeps it across swaps.
class Components::Hep3::CountFrame < Components::Base
  FRAME = "hep3-count"

  def initialize(data:, src: nil)
    @data = data
    @src = src
  end

  def view_template
    turbo_frame_tag(FRAME, src: @src, class: "flex flex-col flex-1 min-w-0 [&>div]:flex-1") do
      count = @data.count

      next if count.nil?

      render Components::Metrics::NumberCard.new(
        label: "Calls",
        color: "var(--voodu-lime)",
        formatted: count[:total].to_s,
        range: @data.custom? ? "custom" : @data.range,
        series: count[:points],
        range_ms: @data.range_ms,
        sub: "distinct calls · each call counted once"
      )
    end
  end
end
