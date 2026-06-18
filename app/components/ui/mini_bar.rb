# frozen_string_literal: true

# Components::UI::MiniBar — 56×4 horizontal utilization bar.
#
# Used inline next to numeric values in the pods table (CPU/mem
# columns) and in metric cards. Caps the fill at 0..100% so a runaway
# data point doesn't visually overflow.
class Components::UI::MiniBar < Components::Base
  def initialize(value:, max: 100, color: "var(--voodu-accent)", width: 56, height: 4)
    @value = value.to_f
    @max = max.to_f
    @color = color
    @width = width
    @height = height
  end

  def view_template
    pct = [[(@value / [@max, 0.001].max) * 100, 0].max, 100].min

    div(
      class: "shrink-0 overflow-hidden",
      style: "width: #{@width}px; height: #{@height}px; background: var(--voodu-border);"
    ) do
      div(style: "width: #{pct}%; height: 100%; background: #{@color};")
    end
  end
end
