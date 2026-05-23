# frozen_string_literal: true

# Components::UI::Badge — small label, optionally with a leading dot.
#
# Use when you need a status-like chip but the StatusPill is too loud
# (e.g. tags in a list, role labels next to a name). Variants map
# 1:1 to the semantic colors in theme.css.
class Components::UI::Badge < Components::Base
  VARIANTS = {
    neutral: "bg-voodu-surface-2 text-voodu-text-2 border border-voodu-border",
    accent:  "bg-voodu-accent-dim text-voodu-accent-2 border border-voodu-accent-line",
    success: "bg-voodu-green-dim text-voodu-green border border-voodu-green/30",
    warning: "bg-voodu-amber-dim text-voodu-amber border border-voodu-amber/30",
    danger:  "bg-voodu-red-dim text-voodu-red border border-voodu-red/30",
    info:    "bg-voodu-blue/15 text-voodu-blue border border-voodu-blue/30"
  }.freeze

  def initialize(variant: :neutral, dot: false, **attrs)
    @variant = variant
    @dot     = dot
    @attrs   = attrs
  end

  def view_template(&)
    span(
      class: tokens(
        "inline-flex items-center gap-1.5 px-2 py-0.5 text-[11px] font-medium rounded-voodu-sm",
        VARIANTS.fetch(@variant, VARIANTS[:neutral]),
        @attrs[:class]
      ),
      **@attrs.except(:class)
    ) do
      span(class: "w-1.5 h-1.5 rounded-full bg-current") if @dot
      yield if block_given?
    end
  end
end
