# frozen_string_literal: true

# Components::UI::SectionCard — bordered section with an uppercase
# header. Mirrors the inspiration's `Card`:
#
#   ┌───────────────────────────┐
#   │ SPEC                      │  ← header: bg-2 + uppercase + 12px
#   ├───────────────────────────┤
#   │  …KvRow…                  │  ← body: zero padding by default
#   │  …KvRow…                  │     (KvRow brings its own padding)
#   └───────────────────────────┘
#
# Pass `pad: true` if the body content is freeform and needs the
# 14px padding the card would otherwise skip.
#
# Optional `action:` slot renders into the header's right end (used
# by EnvCard for the inline "filter keys or values" search input).
class Components::UI::SectionCard < Components::Base
  def initialize(title:, pad: false)
    @title  = title
    @pad    = pad
    @action = nil
  end

  def with_action(&block)
    @action = block
    self
  end

  def view_template(&body)
    section(class: "flex flex-col min-w-0 bg-voodu-surface border border-voodu-border") do
      header(class: "flex items-center px-3.5 py-2.5 border-b border-voodu-border bg-voodu-bg-2") do
        h3(class: "text-[12px] font-semibold uppercase tracking-wider text-voodu-text-2 m-0") { @title }
        div(class: "flex-1")
        @action&.call
      end

      div(class: (@pad ? "p-3.5" : nil), &body)
    end
  end
end
