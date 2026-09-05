# frozen_string_literal: true

# Components::UI::Callout — a block that says what KIND of thing it is.
#
# ## The restraint is the design
#
# The tone is carried by a LEFT RULE and an ICON. The background stays the
# ordinary surface, and the border stays the ordinary border.
#
# The alternative — and what this replaced — was a fully tinted card per tone:
# amber fill for a warning, red fill for a failure. Two of those on one screen
# and the page reads as an incident; four and the operator stops seeing any of
# them. Tint is a volume control, and every block was set to loud.
#
# A 2px rule and a coloured glyph are enough to sort a page at a glance:
# "something to know", "something to fix", "something that worked". That is
# what an operator is doing when they scan — sorting, not being alarmed.
#
# `danger` is the exception and keeps a faint fill. A deploy that failed is the
# one thing on this dashboard that should catch the eye before it is read.
class Components::UI::Callout < Components::Base
  # [rule, icon colour, icon, background]
  TONES = {
    info: ["border-l-voodu-blue", "text-voodu-blue", :InformationCircleOutline, nil],
    warning: ["border-l-voodu-amber", "text-voodu-amber", :ExclamationTriangleOutline, nil],
    danger: ["border-l-voodu-red", "text-voodu-red", :XCircleOutline, "bg-voodu-red-dim"],
    success: ["border-l-voodu-green", "text-voodu-green", :CheckCircleOutline, nil],
    neutral: ["border-l-voodu-border-2", "text-voodu-muted", :InformationCircleOutline, nil]
  }.freeze

  # `title` is the sentence somebody reads first; the block is the detail.
  # `icon: false` drops the glyph for a callout that is mostly a form or a list,
  # where an icon beside a heading is decoration.
  def initialize(tone: :neutral, title: nil, icon: true)
    @tone = TONES.key?(tone) ? tone : :neutral
    @title = title
    @icon = icon
  end

  def view_template(&block)
    rule, icon_color, icon_klass, bg = TONES.fetch(@tone)

    div(class: tokens(
      "border border-voodu-border border-l-2 px-3.5 py-3 flex items-start gap-2.5",
      rule, bg
    )) do
      glyph(icon_klass, icon_color) if @icon

      div(class: "flex flex-col gap-1 min-w-0 flex-1") do
        span(class: "text-[13px] font-medium text-voodu-text") { @title } if @title

        yield_content(&block)
      end
    end
  end

  private

  def glyph(klass, color)
    span(class: "shrink-0 mt-px #{color}", "aria-hidden": "true") do
      render Icon.const_get(klass).new(class: "w-4 h-4")
    end
  end

  # A callout with only a title is legal — the heading IS the message.
  def yield_content(&block)
    return if block.nil?

    yield
  end
end
