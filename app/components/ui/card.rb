# frozen_string_literal: true

# Components::UI::Card — surface container with optional header/footer.
#
# Slot pattern (borrowed from clowk):
#
#   render Components::UI::Card.new
#     .with_header { h2 { "Pods" } }
#     .with_footer { Components::UI::Button.new { "Refresh" } } do
#       div { "..." }
#     end
#
# Variants map to the three surface layers in voodu's theme:
#
#   :default — lifts off the page background (the "card" feel)
#   :flat    — sits flush with surrounding surface (when stacking
#              cards inside cards reads cleaner as one panel)
#   :accent  — purple-tinted edge for the "highlighted / live" card
#              (e.g. the currently-selected island)
class Components::UI::Card < Components::Base
  VARIANTS = {
    default: {
      bg: "bg-voodu-surface",
      border: "border-voodu-border",
      border_inner: "border-voodu-border"
    },
    flat: {
      bg: "bg-transparent",
      border: "border-voodu-border",
      border_inner: "border-voodu-border"
    },
    accent: {
      bg: "bg-voodu-surface",
      border: "border-voodu-accent-line",
      border_inner: "border-voodu-accent-line"
    }
  }.freeze

  def initialize(**attrs)
    @variant = attrs.fetch(:variant, :default)
    @border = attrs.fetch(:border, true)
    @bg = attrs.fetch(:bg, true)
    @content_class = attrs.fetch(:content_class, "px-4 py-3")
    @attrs = attrs.except(:variant, :border, :bg, :content_class)

    @header_block = nil
    @footer_block = nil
  end

  def with_header(&block)
    @header_block = block
    self
  end

  def with_footer(&block)
    @footer_block = block
    self
  end

  def view_template(&body)
    styles = VARIANTS.fetch(@variant, VARIANTS[:default])

    div(
      class: tokens(
        "rounded-voodu-md overflow-hidden",
        ("border #{styles[:border]}" if @border),
        (styles[:bg] if @bg),
        @attrs[:class]
      ),
      **@attrs.except(:class)
    ) do
      div(class: "px-4 py-3 border-b #{styles[:border_inner]}") { @header_block.call } if @header_block
      div(class: @content_class, &body) if body
      div(class: "px-4 py-2 border-t #{styles[:border_inner]} bg-voodu-bg-2") { @footer_block.call } if @footer_block
    end
  end
end
