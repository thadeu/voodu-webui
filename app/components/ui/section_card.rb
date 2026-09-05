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
  # MAX_H — how tall a `scroll:` card gets before its body scrolls instead of
  # the card growing.
  #
  # ON THE SECTION, not on the body, and that placement is what makes two cards
  # in one grid row match. Capping the body caps the maximum and nothing else:
  # a card with nine rows renders at its natural height, a card with
  # twenty-four renders at the cap, and the pair is uneven — which was the bug.
  # Capping the SECTION bounds the grid row, and the row's own stretch brings
  # the shorter card up to it.
  #
  # The pair is then equal at every size: both short when both are short (no
  # empty space invented), both at the cap when either overflows.
  #
  # Roughly eight rows. Enough that the common pod shows its whole environment
  # without scrolling, short enough that a container with sixty variables does
  # not push everything below it off the page.
  MAX_H = "max-h-[420px]"

  # scroll — the card fills its grid cell, caps at MAX_H, and its body scrolls.
  #
  # `min-h-0` at every level of the chain is not decoration: a flex child's
  # default `min-height: auto` refuses to shrink below its content, so without
  # it the body ignores the cap and the card grows anyway. It has to be
  # repeated on each nested flex container the body passes through.
  def initialize(title:, pad: false, scroll: false)
    @title = title
    @pad = pad
    @scroll = scroll
    @action = nil
  end

  # The classes a scrolling card's own body wrapper needs. Exposed so the
  # cards that nest a filter bar above their list can put the scroll on the
  # LIST and leave the filter pinned — see Components::Pods::EnvCard.
  SCROLL_CHAIN = "flex-1 min-h-0 flex flex-col"
  SCROLL_LIST = "flex-1 min-h-0 overflow-y-auto"

  def with_action(&block)
    @action = block
    self
  end

  def view_template(&body)
    section(class: section_class) do
      # shrink-0 so the header keeps its height when the section is capped —
      # otherwise flex takes the space it needs out of the header first.
      header(class: "shrink-0 flex items-center px-3.5 py-2.5 border-b border-voodu-border bg-voodu-surface") do
        h3(class: "text-[12px] font-semibold uppercase tracking-wider text-voodu-text-2 m-0") { @title }
        div(class: "flex-1")
        @action&.call
      end

      div(class: body_class, &body)
    end
  end

  private

  def section_class
    base = "flex flex-col min-w-0 bg-voodu-surface border border-voodu-border"

    @scroll ? "#{base} h-full #{MAX_H}" : base
  end

  def body_class
    classes = []
    classes << "p-3.5" if @pad
    classes << SCROLL_CHAIN if @scroll

    classes.presence&.join(" ")
  end
end
