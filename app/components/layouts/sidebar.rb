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
    { id: :settings, label: "Settings", icon: :Cog6ToothOutline,    path: "/settings" }
  ].freeze

  def initialize(current_path: "/", islands: [], current_island: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
  end

  def view_template
    aside(
      class: "flex w-[220px] flex-col border-r border-voodu-border bg-voodu-surface",
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
    div(class: "flex items-center gap-2 px-4 py-3 border-b border-voodu-border") do
      # Voodu mark — gradient V (matches inspiration logo).
      div(class: "h-6 w-6 rounded-voodu-sm bg-gradient-to-br from-voodu-accent-2 to-voodu-accent", aria: { hidden: "true" })
      div(class: "flex flex-col leading-tight flex-1") do
        span(class: "font-semibold text-sm text-voodu-text") { "voodu" }
        span(class: "font-voodu-mono text-[10.5px] text-voodu-muted") { "v0.13" }
      end
    end
  end

  def islands_section
    div(class: "flex flex-col gap-1 px-2 pt-3") do
      div(class: "flex items-center justify-between px-2 py-1") do
        span(class: "text-[10.5px] font-medium uppercase tracking-wider text-voodu-muted") { "Islands" }
        a(
          href: "/islands/new",
          class: "p-1 rounded text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2",
          aria: { label: "Add island" }
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
      plain "no islands yet."
      br
      a(href: "/islands/new", class: "text-voodu-accent-2 hover:underline") { "add one →" }
    end
  end

  def island_row(island)
    selected = @current_island && island.id == @current_island.id

    a(
      href: "/islands/#{island.id}",
      class: tokens(
        "flex items-center gap-2 px-2 py-1.5 border rounded-voodu-sm transition-colors",
        selected ? "bg-voodu-accent-dim border-voodu-accent-line" : "border-transparent hover:bg-voodu-surface-2"
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
          "#{island.host} · #{island.pods_count || 0} pods"
        end
      end
    end
  end

  def nav_section
    nav(class: "flex flex-col gap-1 px-2 pt-4", aria: { label: "Primary" }) do
      div(class: "px-2 py-1") do
        span(class: "text-[10.5px] font-medium uppercase tracking-wider text-voodu-muted") { "Navigation" }
      end
      div(class: "flex flex-col gap-px") do
        NAV_ITEMS.each { |item| nav_item(item) }
      end
    end
  end

  def nav_item(item)
    active = nav_active?(item)
    icon_klass = Icon.const_get(item[:icon])

    a(
      href: item[:path],
      "aria-current": (active ? "page" : nil),
      class: tokens(
        "flex items-center gap-2.5 px-2.5 py-1.5 rounded-voodu-sm text-[12.5px] transition-colors",
        active ? "bg-voodu-surface-2 text-voodu-text font-medium" : "text-voodu-text-2 hover:bg-voodu-surface-2 hover:text-voodu-text"
      )
    ) do
      render icon_klass.new(class: "w-3.5 h-3.5 shrink-0")
      span(class: "flex-1 text-left") { item[:label] }
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
