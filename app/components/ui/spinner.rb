# frozen_string_literal: true

# Components::UI::Spinner — tiny rotating arc. Drop-in for inline
# loading states and for the "Restarting" StatusPill.
#
# Pure SVG, no JS. `animate-voodu-spin` is defined in theme.css.
class Components::UI::Spinner < Components::Base
  def initialize(color: "currentColor", size: 12, stroke: 3)
    @color = color
    @size = size
    @stroke = stroke
  end

  def view_template
    svg(
      width: @size,
      height: @size,
      viewBox: "0 0 24 24",
      class: "animate-voodu-spin shrink-0"
    ) do |s|
      s.circle(
        cx: 12, cy: 12, r: 9, fill: "none",
        stroke: @color, "stroke-opacity": "0.25", "stroke-width": @stroke
      )
      s.path(
        d: "M21 12a9 9 0 00-9-9",
        fill: "none", stroke: @color,
        "stroke-width": @stroke, "stroke-linecap": "round"
      )
    end
  end
end
