# frozen_string_literal: true

# Components::Layouts::Sidebar — fixed 220px left rail.
#
# Three stacked regions:
#
#   1. Brand     — voodu logo + version chip
#   2. Islands   — list of registered VPSs (one StatusDot + name + meta
#                  per row). Empty state when none registered yet —
#                  this is what M0/M1 sees, M3 fills with real records.
#   3. Navigation — Overview / Pods / Logs / Metrics / Settings.
#                  Active item gets the purple-tinted background +
#                  accent border.
#
# Footer pinned to the bottom shows a placeholder user identity (no
# auth in M0; M-future fills this with the real operator).
class Components::Layouts::Sidebar < Components::Base
  NAV_ITEMS = [
    { id: :overview, label: "Overview", icon: :Squares2x2Outline,   path: "/" },
    { id: :pods,     label: "Pods",     icon: :CubeOutline,         path: "/pods" },
    { id: :logs,     label: "Logs",     icon: :DocumentTextOutline, path: "/logs" },
    { id: :metrics,  label: "Metrics",  icon: :ChartBarOutline,     path: "/metrics" },
    { id: :alerts,   label: "Alerts",   icon: :BellOutline,         path: "/alerts", badge: :alerts_count },
    { id: :settings, label: "Settings", icon: :Cog6ToothOutline,    path: "/settings" }
  ].freeze

  def initialize(current_path: "/", islands: [], current_island: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
  end

  def view_template
    aside(
      class: tokens(
        # Default (< 1100px): off-canvas drawer that slides in via the
        # mobile-nav controller. Lifts above content with a shadow.
        "fixed inset-y-0 left-0 z-50 w-[280px] max-w-[85vw] -translate-x-full transition-transform duration-200 shadow-2xl",
        # 1100px+: in-flow rail of the parent flex container.
        "vmd:static vmd:translate-x-0 vmd:w-[232px] vmd:max-w-none vmd:z-auto vmd:transition-none vmd:shadow-none",
        "flex flex-col border-r border-voodu-border bg-voodu-surface"
      ),
      data: { mobile_nav_target: "sidebar" },
      aria: { label: "Sidebar" }
    ) do
      brand
      islands_section
      nav_section
      div(class: "flex-1")
      footer
    end
  end

  private

  def brand
    div(class: "flex items-center gap-2.5 px-3.5 py-3 border-b border-voodu-border") do
      render img(src: "/mono-white-512.png", alt: "Voodu", class: "h-7.5 w-auto", aria: { hidden: "true" })

      div(class: "flex flex-col leading-tight flex-1") do
        span(class: "font-semibold text-[14px] text-voodu-text tracking-tight") { "Voodu" }
        span(class: "font-voodu-mono text-[10.5px] text-voodu-muted -mt-px") { "v0.13" }
      end
    end
  end

  def islands_section
    div(class: "flex flex-col gap-1.5 px-2.5 pt-3.5") do
      div(class: "flex items-center justify-between px-2 pt-1 pb-0.5") do
        span(class: "text-[10.5px] font-semibold uppercase tracking-[0.06em] text-voodu-muted") { "Servers" }
        a(
          href: "/islands/new",
          class: "inline-flex items-center justify-center w-5 h-5 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2",
          aria: { label: "Add server" }
        ) do
          render Icon::PlusOutline.new(class: "w-3 h-3")
        end
      end

      if @islands.empty?
        empty_islands
      else
        div(class: "flex flex-col gap-px") do
          @islands.each { |island| island_row(island) }
        end
      end
    end
  end

  def empty_islands
    div(class: "px-2 py-3 text-[11px] text-voodu-muted-2") do
      plain "no servers yet."
      br
      a(href: "/islands/new", class: "text-voodu-accent-2 hover:underline") { "add one →" }
    end
  end

  def island_row(island)
    selected = @current_island && island.id == @current_island.id

    a(
      href: "/islands/#{island.id}",
      class: tokens(
        # min-h-11 (44px) matches inspiration's serverRow touch target.
        "flex items-center gap-2.5 p-2 min-h-11 border transition-colors",
        selected ? "bg-voodu-accent-dim border-voodu-accent-line" : "border-transparent hover:bg-[#ffffff08]"
      )
    ) do
      render Components::UI::StatusDot.new(status: island.status || :stopped)
      div(class: "min-w-0 flex-1 flex flex-col leading-tight") do
        span(
          class: tokens(
            "font-voodu-mono text-[12.5px] truncate",
            selected ? "font-semibold text-voodu-accent-2" : "font-medium text-voodu-text"
          )
        ) { island.name }
        span(class: "font-voodu-mono text-[10.5px] text-voodu-muted truncate") do
          count = island.pods_count
          suffix = count.nil? ? "— pods" : "#{count} pods"
          "#{island.host} · #{suffix}"
        end
      end
    end
  end

  def nav_section
    nav(class: "flex flex-col gap-1.5 px-2.5 pt-3.5", aria: { label: "Primary" }) do
      div(class: "px-2 pt-1 pb-0.5") do
        span(class: "text-[10.5px] font-semibold uppercase tracking-[0.06em] text-voodu-muted") { "Navigation" }
      end
      div(class: "flex flex-col gap-px") do
        NAV_ITEMS.each { |item| nav_item(item) }
      end
    end
  end

  # nav_item — active state is the design beta's signature: purple
  # `accent-dim` fill with the matching `accent-line` border and
  # `accent-2` text. Idle items are muted (text-2) with a subtle
  # hover that doesn't pretend to be a click target.
  def nav_item(item)
    active = nav_active?(item)
    icon_klass = Icon.const_get(item[:icon])
    badge_count = nav_badge_count(item[:badge])

    a(
      href: item[:path],
      "aria-current": (active ? "page" : nil),
      class: tokens(
        # min-h-10 (40px) matches inspiration's navBtn touch target.
        "flex items-center gap-2.5 p-2 min-h-10 text-[13px] border transition-colors",
        active ? "bg-voodu-accent-dim text-voodu-accent-2 border-voodu-accent-line font-medium" : "border-transparent text-voodu-text-2 hover:bg-[#ffffff08] hover:text-voodu-text"
      )
    ) do
      render icon_klass.new(class: "w-3.5 h-3.5 shrink-0")
      span(class: "flex-1 text-left") { item[:label] }

      if badge_count&.positive?
        # Subtle red-tinted badge — softer than a solid red pill,
        # matches the inspiration's `navBadge` dim/text palette.
        span(class: "inline-flex items-center justify-center min-w-[18px] h-[18px] px-1.5 text-[10px] font-medium font-voodu-mono bg-voodu-red-dim text-voodu-red") { badge_count.to_s }
      end
    end
  end

  # nav_badge_count — resolves a symbolic badge key (e.g. :alerts_count)
  # into the integer to display. Today every count is mock; once the
  # observability API surfaces real counts we plug them here.
  def nav_badge_count(key)
    return nil unless key

    case key
    when :alerts_count then 2 # TODO: real alerts feed
    end
  end

  # nav_active? — exact match for "/", prefix match for others so
  # /pods AND /pods/foo both highlight the Pods entry.
  def nav_active?(item)
    return @current_path == "/" if item[:path] == "/"

    @current_path.start_with?(item[:path])
  end

  def footer
    div(class: "flex items-center gap-2 px-3 py-2.5 border-t border-voodu-border") do
      div(class: "h-6 w-6 rounded-full bg-voodu-accent shrink-0", aria: { hidden: "true" })
      div(class: "min-w-0 flex-1 flex flex-col leading-tight") do
        span(class: "text-[12px] font-medium text-voodu-text truncate") { "operator" }
        span(class: "font-voodu-mono text-[10.5px] text-voodu-muted") { "local" }
      end
      render Icon::ChevronRightOutline.new(class: "w-3 h-3 text-voodu-muted")
    end
  end
end
