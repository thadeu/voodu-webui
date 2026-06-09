# frozen_string_literal: true

# Components::Logs::ModeTabs — segmented control that flips between the
# two logs surfaces: Follow (live tail, /logs) and Analytics (historical
# search, /logs/analytics). Rendered at the top of both pages so the
# operator can switch without going back to the sidebar.
#
# Why a tab strip and not a second sidebar item: the sidebar marks "Logs"
# active via `current_path.start_with?(logs_path)`, which would light up
# for BOTH surfaces — the in-page tabs disambiguate "which logs view am I
# on" cleanly. Suppressed in drawer/embed mode (the live-tail Page passes
# nothing, so callers just skip rendering it).
#
#   active: :follow | :analytics
class Components::Logs::ModeTabs < Components::Base
  # Analytics is the primary surface (search the warehouse); Follow (live
  # tail) is secondary. Order here drives the tab order left → right.
  TABS = [
    { id: :analytics, label: "Analytics", icon: :MagnifyingGlassOutline, path: :logs_analytics },
    { id: :follow,    label: "Follow",    icon: :BoltOutline,            path: :logs }
  ].freeze

  def initialize(active:)
    @active = active
  end

  def view_template
    nav(
      class: "inline-flex items-center gap-px p-[2px] border border-voodu-border bg-voodu-surface w-fit",
      aria: { label: "Logs view" }
    ) do
      TABS.each { |tab| tab_link(tab) }
    end
  end

  private

  def tab_link(tab)
    active = tab[:id] == @active

    a(
      href: public_send("#{tab[:path]}_path"),
      "aria-current": (active ? "page" : nil),
      class: tokens(
        "inline-flex items-center gap-1.5 px-3 h-7 text-[12px] font-medium border transition-colors",
        active ? "border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2" : "border-transparent text-voodu-text-2 hover:bg-voodu-surface-2 hover:text-voodu-text"
      )
    ) do
      render Icon.const_get(tab[:icon]).new(class: "w-3.5 h-3.5 shrink-0")
      span { tab[:label] }
    end
  end
end
