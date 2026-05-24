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
  # NAV_ITEMS — the :path key maps to a route HELPER name (resolved
  # at render-time against the current request's tenant_key via
  # ApplicationController#default_url_options). Keeping helpers
  # instead of literal strings means future renames (`/metrics` →
  # `/observe/metrics`) are a one-line routes.rb change.
  NAV_ITEMS = [
    { id: :overview, label: "Overview", icon: :Squares2x2Outline,   path: :tenant_root },
    { id: :pods,     label: "Pods",     icon: :CubeOutline,         path: :pods },
    { id: :logs,     label: "Logs",     icon: :DocumentTextOutline, path: :logs },
    { id: :metrics,  label: "Metrics",  icon: :ChartBarOutline,     path: :metrics },
    # { id: :alerts,   label: "Alerts",   icon: :BellOutline,         path: :alerts, badge: :alerts_count },
    { id: :settings, label: "Settings", icon: :Cog6ToothOutline,    path: :settings }
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
        "flex flex-col border-r border-voodu-border bg-voodu-bg-2"
      ),
      data: { mobile_nav_target: "sidebar" },
      aria: { label: "Sidebar" }
    ) do
      brand
      islands_section
      nav_section
      div(class: "flex-1")
      footer_nav
      # footer
    end
  end

  private

  def brand
    div(class: "flex items-center gap-2.5 px-3.5 py-3 border-b border-voodu-border") do
      render img(src: "/mono-white-512.png", alt: "Clowk", class: "h-7.5 w-auto", aria: { hidden: "true" })

      div(class: "flex flex-col leading-tight flex-1") do
        span(class: "font-semibold text-[14px] text-voodu-text tracking-tight") { "Clowk pods" }
      end
    end
  end

  def islands_section
    div(class: "flex flex-col gap-1.5 px-2.5 pt-3.5") do
      div(class: "flex items-center justify-between px-2 pt-1 pb-0.5") do
        span(class: "text-[10.5px] font-semibold uppercase tracking-[0.06em] text-voodu-muted") { "Servers" }
        a(
          href: helpers.new_island_path,
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
      a(href: helpers.new_island_path, class: "text-voodu-accent-2 hover:underline") { "add one →" }
    end
  end

  def island_row(island)
    selected = @current_island && island.id == @current_island.id

    # Switching island = URL swap. Always lands on Overview of the
    # target island (matches the old POST /islands/:id/select
    # behavior — see IslandsController history). No session write
    # needed: the URL itself encodes the context.
    a(
      href: helpers.tenant_root_path(tenant_key: island.key),
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

  # nav_section — the primary nav. Hidden only when the registry is
  # genuinely empty (no islands at all → there's nowhere any link
  # could meaningfully point). On tenant-LESS surfaces with islands
  # present (e.g. /islands) the nav stays visible, scoped to the
  # first island as a safe default — otherwise the sidebar leaves
  # a huge vertical gap between Servers and the bottom-pinned
  # footer entries.
  def nav_section
    return if nav_tenant_key.nil?

    nav(class: "flex flex-col gap-1.5 px-2.5 pt-3.5", aria: { label: "Primary" }) do
      div(class: "px-2 pt-1 pb-0.5") do
        span(class: "text-[10.5px] font-semibold uppercase tracking-[0.06em] text-voodu-muted") { "Navigation" }
      end
      div(class: "flex flex-col gap-px") do
        NAV_ITEMS.each { |item| nav_item(item) }
      end
    end
  end

  # nav_tenant_key — the tenant_key the nav items should resolve to.
  # Preference order:
  #   1. Active island (tenant-scoped pages).
  #   2. First registered island (tenant-LESS pages like /islands
  #      — keeps the operator's "jump back into a server" affordance
  #      visible from the registry page).
  #   3. nil (true empty state, onboarding flow) — nav section
  #      hides itself entirely.
  def nav_tenant_key
    (@current_island || @islands.first)&.key
  end

  # nav_item — active state is the design beta's signature: purple
  # `accent-dim` fill with the matching `accent-line` border and
  # `accent-2` text. Idle items are muted (text-2) with a subtle
  # hover that doesn't pretend to be a click target.
  def nav_item(item)
    active = nav_active?(item)
    icon_klass = Icon.const_get(item[:icon])
    badge_count = nav_badge_count(item[:badge])
    href = helpers.public_send("#{item[:path]}_path", tenant_key: nav_tenant_key)

    a(
      href: href,
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

  # nav_active? — compares the current request path against the
  # nav item's resolved URL. Overview matches exactly (the tenant
  # root is the parent of every other tenant route, so prefix-
  # matching would always hit). Everything else uses prefix match
  # so /<key>/pods AND /<key>/pods/foo both highlight Pods.
  def nav_active?(item)
    href = helpers.public_send("#{item[:path]}_path", tenant_key: nav_tenant_key)
    return @current_path == href if item[:path] == :tenant_root

    @current_path.start_with?(href)
  end

  # footer_nav — tenant-LESS links pinned to the bottom of the
  # sidebar. Today just "Servers" (the registry / management page);
  # future entries (Help, Profile, Logout) hang off here too.
  # Visually mirrors nav_section but without the "Navigation"
  # section heading — these are utility links, not the primary
  # site map.
  def footer_nav
    div(class: "flex flex-col gap-px px-2.5 pb-3 pt-2 border-t border-voodu-border") do
      footer_nav_item(
        label:  "Servers",
        href:   helpers.islands_path,
        icon:   :ServerStackOutline,
        active: @current_path.start_with?("/islands")
      )
    end
  end

  def footer_nav_item(label:, href:, icon:, active:)
    icon_klass = Icon.const_get(icon)
    a(
      href: href,
      "aria-current": (active ? "page" : nil),
      class: tokens(
        "flex items-center gap-2.5 p-2 min-h-10 text-[13px] border transition-colors",
        active ? "bg-voodu-accent-dim text-voodu-accent-2 border-voodu-accent-line font-medium" : "border-transparent text-voodu-text-2 hover:bg-[#ffffff08] hover:text-voodu-text"
      )
    ) do
      render icon_klass.new(class: "w-3.5 h-3.5 shrink-0")
      span(class: "flex-1 text-left") { label }
    end
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
