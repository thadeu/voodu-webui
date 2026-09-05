# frozen_string_literal: true

# Components::UI::Tooltip — a label for a control that has no visible one.
#
# Renders INSIDE a positioned parent that carries the hover group; the parent
# owns `relative` and `group/<name>`, this owns everything else.
#
#   div(class: "relative group/nav") do
#     a(href: …, "aria-label": "Logs") { icon }
#     render Components::UI::Tooltip.new(label: "Logs", group: "nav")
#   end
#
# ## The accessibility, which is not what it looks like
#
# THE TOOLTIP IS `aria-hidden`, and that is the correct wiring rather than a
# shortcut. The reflex is `aria-describedby`, but a description is extra
# information ABOUT a control that already has a name — and here the tooltip
# text IS the name. Wiring it as a description makes a screen reader announce
# "Logs, Logs".
#
# So the accessible name goes on the TRIGGER, as `aria-label`, and this is
# decoration for people who can see it. The caller is responsible for that
# label; a trigger without one is an icon nobody can name, tooltip or not.
#
# `aria-label` and not the visible text, because the text is hidden by CSS when
# collapsed — and `display: none` removes a node from the accessibility tree,
# so the name would disappear exactly when the icon needs it most.
class Components::UI::Tooltip < Components::Base
  SIDES = {
    # [tooltip position, arrow position, arrow borders]
    right: [
      "left-full top-1/2 -translate-y-1/2 ml-2",
      "-left-1 top-1/2 -translate-y-1/2",
      "border-l border-b"
    ],
    left: [
      "right-full top-1/2 -translate-y-1/2 mr-2",
      "-right-1 top-1/2 -translate-y-1/2",
      "border-r border-t"
    ],
    top: [
      "bottom-full left-1/2 -translate-x-1/2 mb-2",
      "-bottom-1 left-1/2 -translate-x-1/2",
      "border-r border-b"
    ]
  }.freeze

  # HOVER — the reveal class, PER GROUP, written out in full.
  #
  # NOT interpolated, and that is the whole reason this constant exists.
  # Tailwind scans SOURCE TEXT for candidate class names: a string built as
  # `"group-hover/#{@group}:opacity-100"` never appears in any file, so the
  # rule is never generated and the tooltip renders permanently invisible —
  # correct markup, correct comment, no CSS, no symptom to grep for.
  #
  # A new group has to be added here. That is the cost of the guardrail, and
  # it is cheap next to a tooltip that silently does nothing.
  HOVER = {
    "nav" => "group-hover/nav:opacity-100",
    "rail" => "group-hover/rail:opacity-100",
    "sender" => "group-hover/sender:opacity-100"
  }.freeze

  # `group` names the hover group the PARENT declares. Named rather than bare
  # because the pages using this already have an unnamed `group` doing
  # something else — the sidebar's is the collapsed state — and sharing it
  # would pop every tooltip on the page at once.
  def initialize(label:, group:, side: :right, visible_when: nil)
    @label = label
    @group = group
    @side = SIDES.key?(side) ? side : :right
    @visible_when = visible_when
  end

  def view_template
    position, arrow_position, arrow_borders = SIDES.fetch(@side)

    span(role: "tooltip", "aria-hidden": "true", class: shell_class(position)) do
      plain @label

      # A rotated square, not a CSS border-triangle, so the 1px border carries
      # around the point. A border-triangle cannot have a border, and next to a
      # bordered bubble it reads as a smudge rather than a tip.
      span("aria-hidden": "true", class: tokens(
        "absolute w-2 h-2 rotate-45 bg-voodu-surface-2 border-voodu-border-2",
        arrow_borders, arrow_position
      ))
    end
  end

  private

  def shell_class(position)
    tokens(
      "pointer-events-none absolute z-50 whitespace-nowrap",
      "px-2 py-1 border border-voodu-border-2 bg-voodu-surface-2",
      "text-[11.5px] text-voodu-text shadow-[var(--voodu-shadow-sm)]",
      position,
      # When the caller only wants it in one state — the sidebar draws it only
      # while collapsed, because expanded the label is already on screen.
      @visible_when || "block",
      "opacity-0 transition-opacity duration-100",
      HOVER.fetch(@group.to_s)
    )
  end
end
