# frozen_string_literal: true

# Components::UI::Logo — the voodu mark. Two-stroke "V":
#
#   - Outer V: gradient from a light brand green (#6ee7b7) to a
#     deeper green (#059669). Sits at full opacity.
#   - Inner v: smaller, dimmer (60% opacity), pure light grey. Adds
#     the subtle depth the brand has in the inspiration.
#
# Ported 1:1 from the inspiration's `Icons.Logo` (icons.jsx). The
# gradient id is namespaced + suffixed so multiple instances on the
# same page never collide.
class Components::UI::Logo < Components::Base
  def initialize(size: 22)
    @size = size
  end

  def view_template
    gid = gradient_id

    svg(
      width: @size, height: @size,
      viewBox: "0 0 24 24", fill: "none",
      "aria-hidden": "true"
    ) do |s|
      s.defs do
        s.linearGradient(id: gid, x1: 0, x2: 24, y1: 0, y2: 24) do
          s.stop(offset: "0", "stop-color": "#6ee7b7")
          s.stop(offset: "1", "stop-color": "#059669")
        end
      end

      # Outer V — gradient stroke.
      s.path(
        d: "M4 5 L12 20 L20 5",
        stroke: "url(##{gid})", "stroke-width": "2.2",
        "stroke-linecap": "round", "stroke-linejoin": "round"
      )

      # Inner v — dim grey for depth.
      s.path(
        d: "M8.5 5 L12 12 L15.5 5",
        stroke: "#e8e8ee", "stroke-width": "2.2",
        "stroke-linecap": "round", "stroke-linejoin": "round",
        opacity: "0.6"
      )
    end
  end

  private

  # Unique id per render — multiple Logos on one page (sidebar + maybe
  # a future "welcome" or footer) shouldn't share a <defs>.
  def gradient_id
    "voodu-logo-#{SecureRandom.hex(4)}"
  end
end
