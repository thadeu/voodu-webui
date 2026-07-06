# frozen_string_literal: true

# Components::Layouts::Topbar — 56px header above content.
#
# Three responsive states (mirrors the inspiration):
#
#   < 1100px (mobile)
#     ☰ · name · pill ………… 🔍 · 25s↻
#     Region/uptime chips hidden. Search-box collapsed into an icon
#     button. Refresh chip drops "updated" + "ago".
#
#   1100–1279px (narrow desktop)
#     servers › name · pill · region · uptime ………… search · updated 25s ago
#     Same as full, but the search box drops its Cmd-K hint.
#
#   ≥ 1280px (full desktop)
#     servers › name · pill · region · uptime ………… search [⌘K] · updated 25s ago
class Components::Layouts::Topbar < Components::Base
  def initialize(current_server: nil, servers: [], updated_at: nil, uptime: nil)
    @current_server = current_server
    @servers = servers
    @updated_at = updated_at
    # uptime is the LIVE host uptime label, sourced from /system on
    # the Overview page. Other pages don't fetch /system, so they
    # pass nil and we fall back to the (stale) Server#uptime — until
    # those pages get their own snapshots, this keeps the chip
    # non-blank but operators know the Overview is the live source.
    @uptime = uptime
  end

  def view_template
    header(
      # min-w-0 lets children with `truncate` actually shrink; without
      # it flexbox happily lets a long server name push the right
      # cluster (search + updated pill) past the viewport edge.
      # voodu-dark — AWS-style fixed-dark topbar: force the dark palette
      # on this subtree so the bar stays dark even in light theme (see
      # `html[data-theme="light"] .voodu-dark` in theme.css).
      class: "voodu-dark relative z-10 flex h-14 items-center gap-2 vmd:gap-2.5 px-3.5 vmd:px-4 border-b border-voodu-border bg-voodu-bg flex-none min-w-0 shadow-voodu-header",
      role: "banner"
    ) do
      hamburger
      if @current_server
        server_breadcrumb
      else
        no_server_hint
      end

      # Spacer — only on desktop. On mobile the breadcrumb keeps its
      # `flex-1` and fills the space itself; adding a second flex-1
      # spacer here would split the row 50/50 and push the right
      # cluster off-screen (the bug we just fixed).
      div(class: "hidden vmd:block flex-1")
      search_box
      search_icon
      theme_toggle
    end
  end

  private

  # theme_toggle — sun/moon quick switch. The initial theme is resolved
  # before paint by the inline script in application.html.erb (sets
  # html[data-theme]); theme_controller flips it on click + keeps the
  # icon in sync. Shows the icon for the theme you'd switch TO (sun in
  # dark, moon in light). The wrong-icon default (sun) is corrected by
  # the controller's connect() the instant it mounts.
  def theme_toggle
    button(
      type: "button",
      data: {controller: "theme", action: "click->theme#toggle"},
      title: "Toggle theme",
      "aria-label": "Toggle light / dark theme",
      class: "inline-flex items-center justify-center w-8 h-8 border border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2 hover:text-voodu-text shrink-0"
    ) do
      span(data: {theme_target: "sun"}) { render Icon::SunOutline.new(class: "w-4 h-4") }
      span(data: {theme_target: "moon"}, hidden: true) { render Icon::MoonOutline.new(class: "w-4 h-4") }
    end
  end

  # Hamburger — visible only below 1100px. Triggers the mobile-nav drawer.
  def hamburger
    button(
      type: "button",
      class: "vmd:hidden inline-flex items-center justify-center w-9 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2 shrink-0",
      data: {action: "click->mobile-nav#toggle"},
      aria: {label: "Open menu"}
    ) do
      render Icon::Bars3Outline.new(class: "w-4 h-4")
    end
  end

  def server_breadcrumb
    div(class: "flex items-center gap-2 vmd:gap-2.5 min-w-0 flex-1 vmd:flex-initial") do
      div(class: "flex items-center gap-1.5 min-w-0") do
        # Org switcher first — the server layer above servers. Then the
        # "servers ›" prefix (1100+) and the server switcher.
        if current_org
          org_switcher
          render Icon::ChevronRightOutline.new(class: "hidden vmd:inline w-2.5 h-2.5 text-voodu-muted")
        end

        span(class: "hidden vmd:inline text-voodu-muted text-[13px]") { "servers" }
        render Icon::ChevronRightOutline.new(class: "hidden vmd:inline w-2.5 h-2.5 text-voodu-muted")

        if @servers.size > 1
          server_switcher
        else
          span(class: "font-voodu-mono text-[13px] font-semibold text-voodu-text truncate") { @current_server.name }
        end
      end

      # DOM id = Turbo Stream broadcast target. State-sync job
      # re-renders this span on every sync (success → :online,
      # failure → :offline) and pushes it to the client without
      # a refresh. See StateSyncServerJob#broadcast_status_change.
      span(id: "server-status-pill-#{@current_server.id}", class: "inline-flex") do
        render Components::UI::StatusPill.new(status: @current_server.status || :stopped)
      end

      # Chips collapse on < 1280px to keep the topbar single-line.
      # `updated` sits right after uptime now (was in the right cluster);
      # the topbar end keeps just search + theme toggle.
      span(class: "hidden vlg:contents") do
        region_chip
        chip("uptime", @uptime || @current_server.uptime)
        updated_pill if @updated_at
      end
    end
  end

  # org_switcher — the server selector, mirroring server_switcher but one
  # level up. Each row lands on that org's root (org_root redirects to the
  # org's first server). server_key:nil keeps the current server key out of
  # the org-switch URL (it belongs to a DIFFERENT org).
  # org_switcher — the org dropdown (switch orgs) + a "Manage orgs" action that
  # opens the org-manager overlay in place. Wrapped in the org-manager controller
  # (with its own Overlay sibling) so "Manage orgs" reaches it — the add-server
  # form's org-manager isn't on server pages, so there's no clash.
  def org_switcher
    div(class: "relative shrink-0", data: {controller: "org-manager"}) do
      div(class: "relative", data: {controller: "dropdown"}) do
        button(
          type: "button",
          class: "inline-flex items-center gap-1.5 text-[13px] font-semibold text-voodu-accent-2 hover:text-voodu-link min-w-0",
          data: {action: "click->dropdown#toggle"}
        ) do
          render Icon::BuildingOffice2Outline.new(class: "w-3.5 h-3.5 shrink-0")
          # Name hides on mobile (icon + chevron stay) so the org, server and
          # status pill don't collide in the narrow topbar — tap opens the list.
          span(class: "hidden vmd:inline truncate max-w-[140px]") { current_org.name }
          render Icon::ChevronDownOutline.new(class: "w-3 h-3 text-voodu-muted shrink-0")
        end

        div(
          hidden: true,
          data: {dropdown_target: "menu"},
          class: "absolute left-0 top-full mt-1 min-w-[220px] z-40 border border-voodu-border bg-voodu-surface shadow-2xl"
        ) do
          div(class: "py-1") { all_orgs.each { |o| org_switcher_row(o) } }
          div(class: "border-t border-voodu-border py-1") do
            button(
              type: "button",
              data: {action: "org-manager#open click->dropdown#close"},
              class: "w-full flex items-center gap-2 px-3 py-1.5 text-left text-[12px] text-voodu-muted hover:bg-voodu-surface-2 hover:text-voodu-text"
            ) do
              render Icon::BuildingOffice2Outline.new(class: "w-3.5 h-3.5 shrink-0")
              span { "Manage orgs" }
            end
          end
        end
      end

      render Components::Orgs::Overlay.new(orgs: all_orgs)
    end
  end

  def org_switcher_row(org)
    selected = org.id == current_org.id
    a(
      href: org_root_path(org_id: org.short_id, server_key: nil),
      class: tokens(
        "w-full flex items-center gap-2 px-3 py-1.5 text-left text-[12px]",
        selected ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text hover:bg-voodu-surface-2"
      )
    ) do
      render Icon::BuildingOffice2Outline.new(class: "w-3.5 h-3.5 shrink-0")
      span(class: "truncate") { org.name }
    end
  end

  def server_switcher
    div(class: "relative", data: {controller: "dropdown"}) do
      button(
        type: "button",
        class: "inline-flex items-center gap-1 font-voodu-mono text-[13px] font-semibold text-voodu-text hover:text-voodu-link",
        data: {action: "click->dropdown#toggle"}
      ) do
        span(class: "truncate") { @current_server.name }
        render Icon::ChevronDownOutline.new(class: "w-3 h-3 text-voodu-muted")
      end

      div(
        hidden: true,
        data: {dropdown_target: "menu"},
        class: "absolute left-0 top-full mt-1 min-w-[240px] z-40 border border-voodu-border bg-voodu-surface shadow-2xl"
      ) do
        div(class: "py-1") { @servers.each { |i| switcher_row(i) } }
        div(class: "border-t border-voodu-border py-1") do
          a(href: servers_path, class: "block px-3 py-1.5 text-[12px] text-voodu-muted hover:bg-voodu-surface-2 hover:text-voodu-text") { "manage servers →" }
        end
      end
    end
  end

  # switcher_row — URL swap. Always lands on the target server's
  # Overview (server root). The old POST flow rewrote
  # session[:current_server_id] and redirected to /; now there's
  # no session state to mutate — the URL itself is the context.
  def switcher_row(server)
    selected = server.id == @current_server.id
    a(
      href: server_root_path(org_id: server.org.short_id, server_key: server.key),
      class: tokens(
        "block w-full flex items-center gap-2 px-3 py-1.5 text-left text-[12px] font-voodu-mono",
        selected ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text hover:bg-voodu-surface-2"
      )
    ) do
      render Components::UI::StatusDot.new(status: server.status)
      span(class: "truncate flex-1") { server.name }
      span(class: "text-[10.5px] text-voodu-muted") { server.host }
    end
  end

  def chip(label, value)
    span(class: "inline-flex items-center gap-1.5 px-2 py-[3px] border border-voodu-border bg-voodu-surface text-[11.5px] whitespace-nowrap") do
      span(class: "text-voodu-muted-2") { label }
      span(class: "font-voodu-mono text-voodu-text-2") { value }
    end
  end

  # region_chip — compound chip rendering when EITHER region or
  # infra is set:
  #   region only  →  "region fra1"
  #   infra only   →  "infra hetzner"
  #   both         →  "region fra1 · hetzner"
  #   neither      →  chip collapses entirely (no DOM)
  #
  # Compound form mirrors the design beta "fra1.hetzner" hint
  # without forcing the operator to pre-format it themselves.
  def region_chip
    region = @current_server.region
    region = nil if region == "—"
    infra = @current_server.infra

    return if region.nil? && infra.nil?

    label = if region && infra
      "region"
    else
      (region ? "region" : "infra")
    end
    value =
      if region && infra
        "#{region} · #{infra}"
      else
        region || infra
      end

    chip(label, value)
  end

  def no_server_hint
    span(class: "text-voodu-muted text-xs") { "no server selected" }
  end

  # Full search box — visible at 1100+. Real button now: clicking
  # opens the command palette (or operator hits Cmd-K from anywhere).
  # The Cmd-K hint only shows at 1280+ (where there's room).
  def search_box
    button(
      type: "button",
      data: {command_palette_open: ""},
      class: "hidden vmd:flex items-center gap-2 px-2.5 h-8 border border-voodu-border bg-voodu-surface w-[260px] vlg:w-[320px] text-voodu-muted hover:bg-voodu-surface-2 hover:text-voodu-text-2 transition-colors",
      role: "search",
      "aria-label": "Open command palette"
    ) do
      render Icon::MagnifyingGlassOutline.new(class: "w-3.5 h-3.5 shrink-0")
      span(class: "text-[13px] flex-1 text-left") { "Search pods, logs, actions…" }
      span(class: "hidden vlg:flex items-center gap-1") do
        render Components::UI::Kbd.new { "⌘" }
        render Components::UI::Kbd.new { "K" }
      end
    end
  end

  # Icon-only search — mobile fallback. Same target as the desktop
  # search button (command palette open).
  def search_icon
    button(
      type: "button",
      data: {command_palette_open: ""},
      class: "vmd:hidden inline-flex items-center justify-center w-9 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2 shrink-0",
      aria: {label: "Open command palette"}
    ) do
      render Icon::MagnifyingGlassOutline.new(class: "w-4 h-4")
    end
  end

  # updated_pill — the entire chip is now clickable and IS the
  # refresh affordance (the old "Refresh all" button is gone — too
  # easy to read as "restart all pods", which it never did).
  #
  # Click navigates to `?refresh=1` which the dashboard controller
  # turns into a cache-bypass on OverviewData. The url uses the
  # current request path so the chip works on every page that
  # honors `?refresh=1`.
  #
  # The "Ns ago" text is driven by the `updated-at` Stimulus
  # controller — ticks every 1s without server polling. The Rails
  # render only sets the initial ISO timestamp; JavaScript handles
  # the human label client-side.
  #
  # Visual:
  #   ● updated  25s ago  ⟳
  #   dot       label       icon
  #
  # The dot's color tracks freshness: green + pulse ONLY when the agent
  # is confirmed online (live data). When it's offline/unknown the data
  # is last-known/stale — the dot goes amber + static so "updated 12d
  # ago" doesn't read as fresh. Same `!= :online` signal as the stale
  # banner + the offline pod rows.
  def updated_pill
    live = @current_server&.status == :online
    dot = live ? "var(--voodu-green)" : "var(--voodu-amber)"

    # Chip-sized (px-2 py-[3px], no fixed height) so it lines up with the
    # region / uptime chips it now sits beside in the breadcrumb.
    a(
      href: refresh_href,
      data: {
        controller: "updated-at",
        action: "click->updated-at#refresh",
        updated_at_iso_value: @updated_at.iso8601
      },
      title: "Click to refresh — bypasses the snapshot cache",
      class: "inline-flex items-center gap-1.5 px-2 py-[3px] border border-voodu-border bg-voodu-surface text-[11.5px] whitespace-nowrap text-voodu-muted hover:bg-voodu-surface-2 hover:text-voodu-text shrink-0"
    ) do
      span(
        class: tokens("inline-block rounded-full", ("animate-voodu-pulse" if live)),
        style: "width: 6px; height: 6px; background: #{dot}; box-shadow: 0 0 0 3px color-mix(in srgb, #{dot} 18%, transparent);"
      )
      span(class: "text-voodu-muted-2") { "updated" }
      span(class: "font-voodu-mono text-voodu-text-2") do
        span(data: {updated_at_target: "label"}) { "now" }
        plain " ago"
      end
      span(class: "inline-flex items-center justify-center w-4 h-4 text-voodu-muted") do
        render Icon::ArrowPathOutline.new(class: "w-3 h-3")
      end
    end
  end

  # refresh_href — preserves the current request path AND existing
  # query string (status filter, etc.), only setting/replacing
  # `refresh=1`. So clicking refresh on `/pods?status=running` lands
  # on `/pods?status=running&refresh=1` — filters survive the
  # refresh, only the snapshot cache gets invalidated.
  def refresh_href
    params = request.query_parameters.merge(refresh: 1)
    "#{request.path}?#{params.to_query}"
  end
end
