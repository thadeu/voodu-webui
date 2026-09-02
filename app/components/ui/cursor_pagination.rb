# frozen_string_literal: true

# Components::UI::CursorPagination — newest / previous / next, for a list paged
# by a row boundary rather than an offset.
#
# WHY IT IS NOT Components::UI::Pagination. That one shows "page N of M", and
# both halves of that phrase are things a cursor deliberately does not know: no
# page number, because a cursor names a row rather than a position, and no
# total, because producing one means counting every match on every render.
# Bending it to render blanks in those slots would leave a component that lies
# about what it can answer.
#
# So there is no "last" control either — the three here are the whole
# vocabulary a cursor can honestly offer:
#
#   ⏮  back to newest   (drop the cursor entirely)
#   ‹  previous page    (rows newer than the first one shown)
#   ›  next page        (rows older than the last one shown)
#
# The hrefs are built by the caller, because only the caller knows which query
# parameters have to survive a page change. Losing a filter by clicking "next"
# is the classic pagination bug, and it comes from a component that thinks it
# knows the URL.
class Components::UI::CursorPagination < Components::Base
  def initialize(newest_href:, prev_href: nil, next_href: nil, frame: nil, label: "items", showing: nil)
    @newest_href = newest_href
    @prev_href = prev_href
    @next_href = next_href
    @frame = frame
    @label = label
    @showing = showing
  end

  def view_template
    # Nothing to page: one screen, no controls. The row count alone is already
    # on the list header.
    return if @prev_href.nil? && @next_href.nil?

    nav(
      class: "flex flex-col vmd:flex-row vmd:items-center gap-2 vmd:gap-3 " \
             "px-3.5 py-2 border border-voodu-border bg-voodu-surface",
      "aria-label": "Pagination"
    ) do
      showing_label
      div(class: "hidden vmd:block flex-1")
      controls
    end
  end

  private

  # No "of N", on purpose — see the class note. What it can say honestly is how
  # many rows are on this page.
  def showing_label
    return if @showing.nil?

    span(class: "text-[11.5px] text-voodu-muted") do
      "#{@showing} #{@label}"
    end
  end

  def controls
    div(class: "flex items-center gap-1.5") do
      control(@newest_href, "Back to newest", "aria-label": "Back to newest") do
        render Icon::ChevronDoubleLeftOutline.new(class: "w-3.5 h-3.5")
      end

      control(@prev_href, "Newer", "aria-label": "Newer") do
        render Icon::ChevronLeftOutline.new(class: "w-3.5 h-3.5")
      end

      control(@next_href, "Older", "aria-label": "Older") do
        render Icon::ChevronRightOutline.new(class: "w-3.5 h-3.5")
      end
    end
  end

  # A nil href renders a DISABLED span, not a missing button: controls that
  # come and go move the two beside them, so the operator's next click lands on
  # whatever slid under the pointer.
  def control(href, title, **attrs, &)
    if href.nil?
      return span(
        class: "inline-flex items-center justify-center w-[26px] h-[26px] border " \
               "border-voodu-border-2 text-voodu-muted-2 opacity-40 cursor-not-allowed",
        "aria-disabled": "true",
        **attrs,
        &
      )
    end

    a(
      href: href,
      title: title,
      class: "inline-flex items-center justify-center w-[26px] h-[26px] border " \
             "border-voodu-border bg-voodu-surface text-voodu-text-2 " \
             "hover:bg-voodu-surface-2 hover:text-voodu-text",
      data: {turbo_frame: @frame, turbo_action: "advance"}.compact,
      **attrs,
      &
    )
  end
end
