# frozen_string_literal: true

# Components::UI::Chip — small bordered inline label.
#
# Three tones (mirror parts.jsx):
#
#   :default  surface-2 fill + border  — generic meta chip
#   :accent   purple-tinted            — selected / live
#   :subtle   transparent + border     — secondary (aliases, ports list)
#
# `mono: true` swaps the font to Geist Mono (host names, ports, ids).
class Components::UI::Chip < Components::Base
  TONES = {
    default: { color: "var(--voodu-text-2)",  bg: "var(--voodu-surface-2)", border: "var(--voodu-border)" },
    accent:  { color: "var(--voodu-accent-2)", bg: "var(--voodu-accent-dim)", border: "var(--voodu-accent-line)" },
    subtle:  { color: "var(--voodu-muted)",   bg: "transparent",            border: "var(--voodu-border)" }
  }.freeze

  def initialize(tone: :default, mono: false, **attrs)
    @tone  = tone
    @mono  = mono
    @attrs = attrs
  end

  def view_template(&)
    t = TONES.fetch(@tone, TONES[:default])

    span(
      class: tokens(
        "inline-flex items-center gap-1.5 px-2 py-[3px] text-[11.5px] font-medium leading-snug whitespace-nowrap border",
        (@mono ? "font-voodu-mono" : nil),
        @attrs[:class]
      ),
      style: "color: #{t[:color]}; background: #{t[:bg]}; border-color: #{t[:border]};",
      **@attrs.except(:class)
    ) { yield if block_given? }
  end
end
