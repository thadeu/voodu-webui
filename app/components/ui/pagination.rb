# frozen_string_literal: true

# Components::UI::Pagination — page N of M, with the way forward and back.
#
# Deliberately not numbered links. Numbered pages earn their clutter when
# somebody needs to jump to a known page, and nobody knows which page a given
# plugin is on — they know it is somewhere, which is what a count and a next
# button are for.
#
# The href is built by the caller, because only the caller knows which of the
# current query parameters have to survive a page change. Losing a filter by
# clicking "next" is the classic pagination bug and it comes from a component
# that thinks it knows the URL.
class Components::UI::Pagination < Components::Base
  def initialize(page:, total_pages:, total:, per_page:, href:, frame: nil, label: "items")
    @page = page
    @total_pages = total_pages
    @total = total
    @per_page = per_page
    @href = href
    @frame = frame
    @label = label
  end

  def view_template
    return if @total_pages <= 1

    nav(
      class: "flex flex-col vmd:flex-row vmd:items-center gap-2 vmd:gap-3 " \
             "px-3.5 py-2 border border-voodu-border bg-voodu-surface",
      "aria-label": "Pagination"
    ) do
      range_label
      div(class: "hidden vmd:block flex-1")
      controls
    end
  end

  private

  # The count is the useful half. "Page 2 of 3" tells you where you are;
  # "26–50 of 61" tells you whether the next click is worth it.
  def range_label
    span(class: "text-[12px] text-voodu-muted") do
      span(class: "font-voodu-mono text-voodu-text-2") { "#{first_on_page}–#{last_on_page}" }
      plain " of "
      span(class: "font-voodu-mono text-voodu-text-2") { @total.to_s }
      plain " #{@label}"
    end
  end

  def controls
    div(class: "flex items-center gap-1.5") do
      step(:previous, "Previous", :ChevronLeftOutline)

      span(class: "px-1.5 text-[12px] text-voodu-muted whitespace-nowrap") do
        plain "Page "
        span(class: "font-voodu-mono text-voodu-text-2") { @page.to_s }
        plain " of "
        span(class: "font-voodu-mono text-voodu-text-2") { @total_pages.to_s }
      end

      step(:next, "Next", :ChevronRightOutline)
    end
  end

  # A disabled edge renders as a span, not a dead anchor: an anchor that goes
  # nowhere is still focusable and still looks clickable.
  def step(direction, text, icon)
    target = (direction == :previous) ? @page - 1 : @page + 1
    disabled = (direction == :previous) ? @page <= 1 : @page >= @total_pages

    shared = "inline-flex items-center gap-1 px-2.5 h-8 border text-[12px] font-medium"

    if disabled
      return span(
        class: tokens(shared, "border-voodu-border text-voodu-muted-2 cursor-default"),
        "aria-disabled": "true"
      ) { chevron_label(text, icon, direction) }
    end

    a(
      href: @href.call(target),
      data: @frame ? {turbo_frame: @frame} : {},
      class: tokens(shared, "border-voodu-border bg-voodu-surface text-voodu-text-2",
        "hover:bg-voodu-surface-2 hover:text-voodu-text transition-colors"),
      "aria-label": text
    ) { chevron_label(text, icon, direction) }
  end

  def chevron_label(text, icon, direction)
    klass = Icon.const_get(icon)

    render(klass.new(class: "w-3.5 h-3.5 shrink-0")) if direction == :previous
    span(class: "hidden vmd:inline") { text }
    render(klass.new(class: "w-3.5 h-3.5 shrink-0")) if direction == :next
  end

  def first_on_page = @total.zero? ? 0 : ((@page - 1) * @per_page) + 1

  def last_on_page = [@page * @per_page, @total].min
end
