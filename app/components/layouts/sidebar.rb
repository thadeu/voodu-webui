# frozen_string_literal: true

# Components::Layouts::Sidebar — left rail with two width modes on
# vmd+ viewports:
#
#   EXPANDED  — 232px. Brand (logo + "Clowk Voodu"), Servers section
#               with full name + IP, Navigation with labels + badges,
#               collapse toggle in the footer.
#
#   COLLAPSED — 56px. Logo only, server list shows 2-letter avatars
#               with a status-colored background, nav shows icons only
#               (badges still bubble out), expand toggle in the footer.
#
# Stacked regions (top → bottom):
#
#   1. Brand     — voodu logo + "Clowk Voodu" wordmark (wordmark hides
#                  when collapsed)
#   2. Servers   — list of registered VPSs. Expanded: StatusDot + name
#                  + meta. Collapsed: 2-letter avatar tile bg-tinted
#                  by status (green online, amber restarting, red
#                  failure).
#   3. Navigation — Overview / Pods / Logs / Metrics / Alerts /
#                  Settings. Active item gets the purple-tinted
#                  background + accent border. Labels hide when
#                  collapsed; alert badge stays bubbled top-right
#                  of the icon.
#   4. Footer    — single collapse/expand chevron toggle.
#
# State persists in localStorage via SidebarCollapseController. State
# is communicated to children via Tailwind's `vmd:group-data-[collapsed]`
# variants on the aside root — no per-child JS, no Phlex branching.
class Components::Layouts::Sidebar < Components::Base
  # NAV_ITEMS — the :path key maps to a route HELPER name (resolved
  # at render-time against the current request's tenant_key via
  # ApplicationController#default_url_options). Keeping helpers
  # instead of literal strings means future renames (`/metrics` →
  # `/observe/metrics`) are a one-line routes.rb change.
  NAV_ITEMS = [
    { id: :overview, label: "Overview", icon: :Squares2x2Outline,   path: :tenant_root },
    { id: :pods,     label: "Pods",     icon: :CubeOutline,         path: :pods },
    { id: :metrics,  label: "Metrics",  icon: :ChartBarOutline,     path: :metrics },
    { id: :logs,     label: "Logs",     icon: :DocumentTextOutline, path: :logs },
    { id: :alerts,   label: "Alerts",   icon: :BellOutline,         path: :alerts, badge: :alerts_count },
    { id: :settings, label: "Settings", icon: :Cog6ToothOutline,    path: :settings }
  ].freeze

  def initialize(current_path: "/", islands: [], recent_islands: nil, current_island: nil)
    @current_path    = current_path
    @islands         = islands
    @recent_islands  = recent_islands
    @current_island  = current_island
  end

  def view_template
    aside(
      class: tokens(
        # Default (< 1100px): off-canvas drawer that slides in via the
        # mobile-nav controller. Lifts above content with a shadow.
        "fixed inset-y-0 left-0 z-50 w-[280px] max-w-[85vw] -translate-x-full transition-transform duration-200 shadow-2xl",
        # vmd+: in-flow rail with width animation. `vmd:relative` so
        # the collapse_handle can position absolutely against the
        # sidebar (rather than against some unintended ancestor).
        # `vmd:inset-auto` clears the mobile `inset-y-0 left-0`
        # offsets that don't apply once we're no longer fixed.
        "vmd:relative vmd:inset-auto vmd:translate-x-0 vmd:max-w-none vmd:z-auto vmd:shadow-none",
        "vmd:w-[232px] vmd:data-[collapsed]:w-[56px]",
        "vmd:transition-[width] vmd:duration-200 vmd:ease-out",
        # `group` so descendants can read [data-collapsed] via
        # group-data-* variants without per-child JS.
        "group",
        "flex flex-col border-r border-voodu-border bg-voodu-bg-2"
      ),
      data: {
        controller:        "sidebar-collapse",
        mobile_nav_target: "sidebar",
        # Default to collapsed in the rendered HTML — JS expands on
        # connect() if localStorage says so. Avoids the "page loaded,
        # then sidebar visibly closes" flicker on every reload.
        # `vmd:` prefix on every group-data-[collapsed]:* descendant
        # keeps mobile unaffected: the off-canvas drawer still shows
        # the full sidebar regardless of this attribute.
        collapsed:         ""
      },
      aria: { label: "Sidebar" }
    ) do
      # Turbo Stream subscriptions — one per visible island so the
      # status dot in each row flips live when its state-sync job
      # completes (success → :online, failure → :offline). The
      # current_island's subscription also covers the topbar
      # status pill (same channel; broadcast carries both targets).
      recent_islands_to_render.each do |island|
        turbo_stream_from "island-state-#{island.id}"
      end

      brand
      islands_section
      nav_section
      div(class: "flex-1")
      collapse_footer
      collapse_handle
    end
  end

  private

  # brand — logo + "Clowk Voodu" wordmark. Wordmark collapses; logo
  # stays. Padding shifts to center the logo when collapsed.
  def brand
    div(
      class: tokens(
        "flex items-center gap-2.5 px-3.5 h-14 border-b border-voodu-border shrink-0",
        "vmd:group-data-[collapsed]:px-0 vmd:group-data-[collapsed]:justify-center vmd:group-data-[collapsed]:gap-0"
      )
    ) do
      render img(
        src:   "/mark-mint.svg",
        alt:   "Clowk",
        class: "h-8 w-auto",
        aria:  { hidden: "true" }
      )

      div(class: "flex flex-col leading-tight flex-1 vmd:group-data-[collapsed]:hidden") do
        span(class: "font-semibold text-[14px] text-voodu-text tracking-tight") { "Clowk Voodu" }
      end
    end
  end

  def islands_section
    div(class: "flex flex-col gap-1.5 px-2.5 pt-3.5 vmd:group-data-[collapsed]:px-1.5") do
      # Section header (label + count + add button) hides entirely
      # when collapsed — the rail isn't wide enough to read it.
      div(class: "flex items-center justify-between px-2 pt-1 pb-0.5 vmd:group-data-[collapsed]:hidden") do
        span(class: "inline-flex items-baseline gap-1.5") do
          span(class: "text-[10.5px] font-semibold uppercase tracking-[0.06em] text-voodu-muted") { "Servers" }
          if @islands.any?
            span(class: "font-voodu-mono text-[10.5px] text-voodu-muted-2") { "(#{@islands.size})" }
          end
        end
        a(
          href:  new_island_path,
          class: "inline-flex items-center justify-center w-5 h-5 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2",
          aria:  { label: "Add server" }
        ) do
          render Icon::PlusOutline.new(class: "w-3 h-3")
        end
      end

      list = recent_islands_to_render
      if list.empty?
        empty_islands
      else
        div(class: "flex flex-col gap-px") do
          list.each { |island| island_row(island) }
          see_all_link
        end
      end
    end
  end

  def recent_islands_to_render
    return @recent_islands if @recent_islands

    begin
      recent_islands
    rescue NoMethodError
      @islands
    end
  end

  # see_all_link — when collapsed becomes an icon-only square so the
  # "manage servers" affordance never disappears.
  def see_all_link
    a(
      href: islands_path,
      title: "See all servers",
      class: tokens(
        "flex items-center gap-2.5 p-2 min-h-9 border border-transparent text-[12px] text-voodu-text-2",
        "hover:bg-voodu-hover hover:text-voodu-accent-2 transition-colors",
        "vmd:group-data-[collapsed]:justify-center vmd:group-data-[collapsed]:p-1.5 vmd:group-data-[collapsed]:min-h-0"
      )
    ) do
      render Icon::ServerStackOutline.new(class: "w-3.5 h-3.5 text-voodu-muted shrink-0")
      span(class: "flex-1 vmd:group-data-[collapsed]:hidden") { "See all servers" }
      span(class: "vmd:group-data-[collapsed]:hidden") do
        render Icon::ArrowRightOutline.new(class: "w-3 h-3 text-voodu-muted shrink-0")
      end
    end
  end

  def empty_islands
    div(class: "px-2 py-3 text-[11px] text-voodu-muted-2 vmd:group-data-[collapsed]:hidden") do
      plain "no servers yet."
      br
      a(href: new_island_path, class: "text-voodu-accent-2 hover:underline") { "add one →" }
    end
  end

  # island_row — two visual modes:
  #
  #   Expanded:  [● dot] [name + host meta]
  #   Collapsed: [2-letter avatar with status-tinted background]
  #
  # The `title` attribute supplies a native tooltip when collapsed
  # so the operator can confirm which server they're hovering.
  def island_row(island)
    selected = @current_island && island.id == @current_island.id
    status   = (island.status || :stopped).to_sym
    letters  = avatar_letters_for(island.name)

    a(
      href: tenant_root_path(tenant_key: island.key),
      title: "#{island.name} · #{island.host}",
      class: tokens(
        "flex items-center gap-2.5 p-2 min-h-11 border transition-colors",
        "vmd:group-data-[collapsed]:justify-center vmd:group-data-[collapsed]:p-1 vmd:group-data-[collapsed]:min-h-0 vmd:group-data-[collapsed]:gap-0",
        # Selected row: accent bg + border in EXPANDED state only.
        # When collapsed, the avatar tile itself carries the accent
        # tint — doubling them (row bg + avatar bg both purple)
        # reads as two stacked highlights.
        selected ? "bg-voodu-accent-dim border-voodu-accent-line vmd:group-data-[collapsed]:bg-transparent vmd:group-data-[collapsed]:border-transparent" : "border-transparent hover:bg-voodu-hover"
      )
    ) do
      # Status dot — expanded view only. DOM id is the Turbo
      # Stream broadcast target. StateSyncIslandJob re-renders
      # this span on every sync result and the dot flips live
      # without a page refresh. See
      # StateSyncIslandJob#broadcast_status_change.
      span(
        id:    "island-status-dot-#{island.id}",
        class: "shrink-0 vmd:group-data-[collapsed]:hidden"
      ) do
        render Components::UI::StatusDot.new(status: status)
      end

      # Name + meta — expanded view only.
      div(class: "min-w-0 flex-1 flex flex-col leading-tight vmd:group-data-[collapsed]:hidden") do
        span(
          class: tokens(
            "font-voodu-mono text-[12.5px] truncate",
            selected ? "font-semibold text-voodu-accent-2" : "font-medium text-voodu-text"
          )
        ) { island.name }

        span(class: "font-voodu-mono text-[10.5px] text-voodu-muted truncate") do
          count  = island.pods_count
          suffix = count.nil? ? "— pods" : "#{count} pods"
          "#{island.host} · #{suffix}"
        end
      end

      # Avatar — collapsed view only. Background + text tinted by
      # status; subtle inset border so it reads against the rail bg.
      # When this row is the currently selected server, the avatar
      # gets an accent (purple) override — the topbar already shows
      # its live status, and the accent matches the row's expanded
      # selected state for consistent "this is where you are" cue.
      span(
        class: "hidden vmd:group-data-[collapsed]:inline-flex items-center justify-center w-8 h-8 font-voodu-mono text-[10.5px] font-semibold uppercase tracking-tight",
        style: avatar_style_for(status, selected: selected),
        aria:  { hidden: "true" }
      ) { letters }
    end
  end

  # avatar_letters_for — first two alphanumeric characters of the
  # name, uppercased. Strips separators so "local-debian" reads as
  # "LO" and "fsw-esl" as "FS", matching what the operator naturally
  # parses as the start of the name.
  def avatar_letters_for(name)
    name.to_s.gsub(/[^a-zA-Z0-9]/, "")[0, 2].to_s.upcase
  end

  # avatar_style_for — status → background + text + inset-border
  # tint. Mirrors the palette StatusDot uses so the two
  # representations of "this server is X" agree on color.
  #
  # selected — when this is the currently-active navigation island,
  # the accent (purple) overrides the status tint. Rationale: the
  # topbar already surfaces the LIVE status of the active server
  # (the green "Online" pill in the screenshots), so repeating it
  # on the sidebar avatar is noise. The accent here mirrors the
  # expanded-state's accent border so collapsed/expanded both read
  # as "this is your active context" without ambiguity.
  def avatar_style_for(status, selected: false)
    if selected
      return "background: var(--voodu-accent-dim); color: var(--voodu-accent-2); " \
             "box-shadow: inset 0 0 0 1px var(--voodu-accent-line);"
    end

    case status
    when :online, :running
      "background: var(--voodu-green-dim); color: var(--voodu-green); " \
        "box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--voodu-green) 35%, transparent);"
    when :restarting
      "background: var(--voodu-amber-dim); color: var(--voodu-amber); " \
        "box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--voodu-amber) 35%, transparent);"
    when :offline, :error
      "background: var(--voodu-red-dim); color: var(--voodu-red); " \
        "box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--voodu-red) 35%, transparent);"
    else
      "background: var(--voodu-surface-2); color: var(--voodu-muted); " \
        "box-shadow: inset 0 0 0 1px var(--voodu-border);"
    end
  end

  def nav_section
    return if nav_tenant_key.nil?

    nav(
      class: "flex flex-col gap-1.5 px-2.5 pt-3.5 vmd:group-data-[collapsed]:px-1.5",
      aria:  { label: "Primary" }
    ) do
      div(class: "px-2 pt-1 pb-0.5 vmd:group-data-[collapsed]:hidden") do
        span(class: "text-[10.5px] font-semibold uppercase tracking-[0.06em] text-voodu-muted") { "Navigation" }
      end
      div(class: "flex flex-col gap-px") do
        NAV_ITEMS.each { |item| nav_item(item) }
      end
    end
  end

  def nav_tenant_key
    (@current_island || @islands.first)&.key
  end

  # nav_item — collapsed view: icon centered, label hidden, badge
  # bubbled top-right of the icon. Expanded view: icon + label +
  # right-aligned badge as before.
  def nav_item(item)
    active      = nav_active?(item)
    icon_klass  = Icon.const_get(item[:icon])
    badge_count = nav_badge_count(item[:badge])
    href        = public_send("#{item[:path]}_path", tenant_key: nav_tenant_key)

    a(
      href:           href,
      title:          item[:label],
      "aria-current": (active ? "page" : nil),
      class:          tokens(
        "flex items-center gap-2.5 p-2 min-h-10 text-[13px] border transition-colors",
        "vmd:group-data-[collapsed]:justify-center vmd:group-data-[collapsed]:p-2 vmd:group-data-[collapsed]:min-h-0 vmd:group-data-[collapsed]:gap-0",
        active ? "bg-voodu-accent-dim text-voodu-accent-2 border-voodu-accent-line font-medium" : "border-transparent text-voodu-text-2 hover:bg-voodu-hover hover:text-voodu-text"
      )
    ) do
      # Icon wrapper — relative so the collapsed badge can position
      # itself against the icon when there's no label to sit beside.
      span(class: "relative inline-flex shrink-0") do
        render icon_klass.new(class: "w-4 h-4 shrink-0")

        # Collapsed-state badge — small dot in the top-right of the
        # icon. Only renders when there's a count > 0; only visible
        # when the sidebar is collapsed.
        if badge_count&.positive?
          span(
            class: "hidden vmd:group-data-[collapsed]:inline-flex absolute -top-1 -right-1 items-center justify-center min-w-[12px] h-[12px] px-1 text-[9px] font-medium font-voodu-mono bg-voodu-red-dim text-voodu-red rounded-full leading-none",
            aria:  { label: "#{badge_count} alerts" }
          ) { badge_count.to_s }
        end
      end

      span(class: "flex-1 text-left vmd:group-data-[collapsed]:hidden") { item[:label] }

      # Expanded-state badge — inline right-aligned pill, same look
      # as before. Hidden when collapsed (the icon badge takes over).
      if badge_count&.positive?
        span(class: "inline-flex items-center justify-center min-w-[18px] h-[18px] px-1.5 text-[10px] font-medium font-voodu-mono bg-voodu-red-dim text-voodu-red vmd:group-data-[collapsed]:hidden") { badge_count.to_s }
      end
    end
  end

  def nav_badge_count(key)
    return nil unless key

    case key
    when :alerts_count then 2 # TODO: real alerts feed
    end
  end

  def nav_active?(item)
    href = public_send("#{item[:path]}_path", tenant_key: nav_tenant_key)
    return @current_path == href if item[:path] == :tenant_root

    @current_path.start_with?(href)
  end

  # collapse_footer — explicit chevron button at the bottom of the
  # sidebar. Kept alongside the edge handle so operators have BOTH
  # affordances: the visible button (discoverability) AND the edge
  # rail (NR / Linear style, snappier for repeat use). Both toggle
  # the same controller action.
  #
  # The chevron's `transform` rotates 180° when the sidebar is
  # collapsed so a single icon serves both states (Left points to
  # collapse → expanded; Right points to expand → collapsed).
  def collapse_footer
    div(class: "hidden vmd:flex border-t border-voodu-border shrink-0 p-2 vmd:group-data-[collapsed]:justify-center") do
      button(
        type:  "button",
        title: "Toggle sidebar",
        "aria-label": "Toggle sidebar",
        data:  { action: "click->sidebar-collapse#toggle" },
        class: tokens(
          "inline-flex items-center justify-center w-8 h-8",
          "text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2",
          "transition-colors"
        )
      ) do
        span(
          data:  { sidebar_collapse_target: "icon" },
          class: "inline-flex transition-transform duration-200"
        ) do
          render Icon::ChevronDoubleLeftOutline.new(class: "w-3.5 h-3.5")
        end
      end
    end
  end

  # collapse_handle — thin clickable rail on the right edge of the
  # sidebar that toggles the collapsed state. Borrowed from the
  # New Relic / Linear pattern: a subtle vertical line that becomes
  # accent-colored on hover, with a tooltip ("Collapse" / "Expand")
  # appearing to the right.
  #
  # Coexists with the footer button; they target the same controller
  # action. Operator gets two affordances — the obvious one in the
  # footer for first-time discovery, the quick edge rail for power
  # use. Cost: one extra DOM node + a few classes.
  #
  # Vertical position: top-[40%] rather than top-1/2 so the handle
  # sits roughly in line with the middle of the Navigation section
  # (between Pods and Logs items in a typical layout), instead of
  # the geometric center of the sidebar (which falls below the nav
  # in the empty spacer region — visually "floating" and easy to
  # miss).
  #
  # Only renders at vmd+ — below the breakpoint the sidebar is an
  # off-canvas drawer driven by the hamburger; an edge handle would
  # conflict with the swipe-to-close gesture.
  def collapse_handle
    div(
      aria: { hidden: "true" },
      class: tokens(
        "hidden vmd:block",
        # Absolute against the sidebar (vmd:relative). Anchored at
        # 40% from top so it lands inside the Navigation section
        # rather than the empty spacer below it.
        #
        # `-right-3` shifts the container 12px past the sidebar's
        # right border, putting the visible line in the gutter
        # OUTSIDE the sidebar — clears the active nav item's right
        # border zone, avoiding the visual conflict where a hovered
        # handle line could be misread as part of the selected nav
        # item's outline.
        "absolute top-[40%] -translate-y-1/2 -right-3",
        "h-20 w-3 z-10",
        # Named group so the line + tooltip can react to hover
        # without colliding with the outer `group` that owns
        # the collapsed/expanded state.
        "group/handle"
      )
    ) do
      button(
        type:         "button",
        "aria-label": "Toggle sidebar",
        data:         { action: "click->sidebar-collapse#toggle" },
        class: tokens(
          "absolute inset-0",
          "flex items-center justify-center cursor-pointer",
          "focus:outline-none"
        )
      ) do
        # Visible line with three states:
        #   1. Mouse off sidebar    → transparent (invisible)
        #   2. Mouse over sidebar   → muted (discoverable hint)
        #   3. Mouse over the line  → accent + slightly larger
        #
        # `group-hover:` (no name) targets hover on the OUTER `group`
        # class on the aside — i.e. anywhere over the sidebar — so
        # the line surfaces as soon as the operator's cursor enters
        # the rail, not only when they happen to land on the 12px
        # edge container. `group-hover/handle:` (named) layers the
        # stronger accent state for landing on the line itself.
        span(
          aria:  { hidden: "true" },
          class: tokens(
            "block h-12 w-px",
            "bg-transparent transition-all duration-150",
            "group-hover:bg-voodu-muted/50",
            "group-hover/handle:!bg-voodu-accent",
            "group-hover/handle:w-0.5 group-hover/handle:h-14"
          )
        )
      end

      # Tooltip — slides into view to the right of the handle on
      # hover. Two spans for the label so the same DOM serves both
      # states; vmd:group-data-[collapsed] (from the OUTER sidebar
      # group) swaps which one renders.
      span(
        class: tokens(
          "absolute left-full top-1/2 -translate-y-1/2 ml-3",
          "px-2.5 py-1 bg-voodu-surface-2 border border-voodu-border-2",
          "text-[11px] font-medium text-voodu-text whitespace-nowrap",
          "shadow-lg pointer-events-none z-20",
          "opacity-0 group-hover/handle:opacity-100",
          "transition-opacity duration-150"
        )
      ) do
        span(class: "vmd:group-data-[collapsed]:hidden") { "Collapse" }
        span(class: "hidden vmd:group-data-[collapsed]:inline") { "Expand" }
      end
    end
  end
end
