# frozen_string_literal: true

# Components::Layouts::Breadcrumb — AWS-style trail strip that sits
# below the (dark) topbar on full pages, spanning the content column.
#
#   Overview  ›  Pods  ›  fsw-controller.5c50
#
# Only rendered as part of the Dashboard chrome, so it appears on root
# pages only — drawer-mode views skip the chrome entirely (no crumb),
# and modal overlays leave the page (and its crumb) untouched.
#
# `crumbs` is an ordered array of `{ label:, href: }` hashes. The LAST
# crumb is the current page → plain text, no link. Earlier crumbs link
# when they carry an :href, otherwise render as muted text.
class Components::Layouts::Breadcrumb < Components::Base
  def initialize(crumbs:)
    @crumbs = Array(crumbs).compact
  end

  def view_template
    crumbs = with_active_tab(@crumbs)
    return if crumbs.empty?

    nav(
      aria: {label: "Breadcrumb"},
      class: "shrink-0 flex items-center h-10 px-3.5 vmd:px-6 border-b border-voodu-border bg-voodu-bg overflow-x-auto scrollbar-hidden"
    ) do
      ol(class: "flex items-center gap-1.5 m-0 p-0 list-none text-[12.5px] whitespace-nowrap") do
        last = crumbs.length - 1
        crumbs.each_with_index do |crumb, i|
          li(class: "flex items-center gap-1.5 min-w-0") do
            crumb_node(crumb, i == last)

            unless i == last
              render Icon::ChevronRightOutline.new(class: "w-3 h-3 text-voodu-muted-2 shrink-0")
            end
          end
        end
      end
    end
  end

  private

  # Contract: whenever the request carries a `?tab=` query param, append
  # it as the current crumb and turn the section (previously-last) crumb
  # into a link to the tab-less page. Lives here — not in the per-page
  # crumb builders — so EVERY breadcrumb gains the behaviour for free
  # (e.g. /alerts?tab=destinations → Overview › Alerts › Destinations).
  def with_active_tab(crumbs)
    crumbs = Array(crumbs).compact.map(&:dup)
    tab = request ? request.query_parameters["tab"].to_s : ""
    return crumbs if tab.blank? || crumbs.empty?

    crumbs.last[:href] ||= request.path
    crumbs << {label: tab_label(tab)}
    crumbs
  end

  # "destinations" → "Destinations", "some-tab" → "Some Tab".
  def tab_label(tab)
    tab.tr("-_", " ").split.map(&:capitalize).join(" ")
  end

  def crumb_node(crumb, current)
    label = crumb[:label].to_s
    href = crumb[:href]

    if current
      span(class: "text-voodu-text font-medium truncate", "aria-current": "page") { label }
    elsif href
      a(
        href: href,
        class: "text-voodu-link hover:text-voodu-link-2 hover:underline transition-colors truncate"
      ) { label }
    else
      span(class: "text-voodu-muted truncate") { label }
    end
  end
end
