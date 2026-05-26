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
  def initialize(current_island: nil, islands: [], updated_at: nil, uptime: nil)
    @current_island = current_island
    @islands        = islands
    @updated_at     = updated_at
    # uptime is the LIVE host uptime label, sourced from /system on
    # the Overview page. Other pages don't fetch /system, so they
    # pass nil and we fall back to the (stale) Island#uptime — until
    # those pages get their own snapshots, this keeps the chip
    # non-blank but operators know the Overview is the live source.
    @uptime         = uptime
  end

  def view_template
    header(
      # min-w-0 lets children with `truncate` actually shrink; without
      # it flexbox happily lets a long island name push the right
      # cluster (search + updated pill) past the viewport edge.
      class: "flex h-14 items-center gap-2 vmd:gap-2.5 px-3.5 vmd:px-4 border-b border-voodu-border bg-voodu-bg flex-none min-w-0",
      role: "banner"
    ) do
      hamburger
      if @current_island
        island_breadcrumb
      else
        no_island_hint
      end

      # Spacer — only on desktop. On mobile the breadcrumb keeps its
      # `flex-1` and fills the space itself; adding a second flex-1
      # spacer here would split the row 50/50 and push the right
      # cluster off-screen (the bug we just fixed).
      div(class: "hidden vmd:block flex-1")
      search_box
      search_icon
      updated_pill if @current_island && @updated_at
    end
  end

  private

  # Hamburger — visible only below 1100px. Triggers the mobile-nav drawer.
  def hamburger
    button(
      type: "button",
      class: "vmd:hidden inline-flex items-center justify-center w-9 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2 shrink-0",
      data: { action: "click->mobile-nav#toggle" },
      aria: { label: "Open menu" }
    ) do
      render Icon::Bars3Outline.new(class: "w-4 h-4")
    end
  end

  def island_breadcrumb
    div(class: "flex items-center gap-2 vmd:gap-2.5 min-w-0 flex-1 vmd:flex-initial") do
      div(class: "flex items-center gap-1.5 min-w-0") do
        # "servers ›" prefix only on 1100+.
        span(class: "hidden vmd:inline text-voodu-muted text-[13px]") { "servers" }
        render Icon::ChevronRightOutline.new(class: "hidden vmd:inline w-2.5 h-2.5 text-voodu-muted")

        if @islands.size > 1
          island_switcher
        else
          span(class: "font-voodu-mono text-[13px] font-semibold text-voodu-text truncate") { @current_island.name }
        end
      end

      # DOM id = Turbo Stream broadcast target. State-sync job
      # re-renders this span on every sync (success → :online,
      # failure → :offline) and pushes it to the client without
      # a refresh. See StateSyncIslandJob#broadcast_status_change.
      span(id: "island-status-pill-#{@current_island.id}", class: "inline-flex") do
        render Components::UI::StatusPill.new(status: @current_island.status || :stopped)
      end

      # Chips collapse on < 1280px to keep the topbar single-line.
      span(class: "hidden vlg:contents") do
        region_chip
        chip("uptime", @uptime || @current_island.uptime)
      end
    end
  end

  def island_switcher
    div(class: "relative", data: { controller: "dropdown" }) do
      button(
        type: "button",
        class: "inline-flex items-center gap-1 font-voodu-mono text-[13px] font-semibold text-voodu-text hover:text-voodu-accent-2",
        data: { action: "click->dropdown#toggle" }
      ) do
        span(class: "truncate") { @current_island.name }
        render Icon::ChevronDownOutline.new(class: "w-3 h-3 text-voodu-muted")
      end

      div(
        hidden: true,
        data: { dropdown_target: "menu" },
        class: "absolute left-0 top-full mt-1 min-w-[240px] z-40 border border-voodu-border bg-voodu-surface shadow-2xl"
      ) do
        div(class: "py-1") { @islands.each { |i| switcher_row(i) } }
        div(class: "border-t border-voodu-border py-1") do
          a(href: islands_path, class: "block px-3 py-1.5 text-[12px] text-voodu-muted hover:bg-voodu-surface-2 hover:text-voodu-text") { "manage servers →" }
        end
      end
    end
  end

  # switcher_row — URL swap. Always lands on the target island's
  # Overview (tenant root). The old POST flow rewrote
  # session[:current_island_id] and redirected to /; now there's
  # no session state to mutate — the URL itself is the context.
  def switcher_row(island)
    selected = island.id == @current_island.id
    a(
      href: tenant_root_path(tenant_key: island.key),
      class: tokens(
        "block w-full flex items-center gap-2 px-3 py-1.5 text-left text-[12px] font-voodu-mono",
        selected ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text hover:bg-voodu-surface-2"
      )
    ) do
      render Components::UI::StatusDot.new(status: island.status)
      span(class: "truncate flex-1") { island.name }
      span(class: "text-[10.5px] text-voodu-muted") { island.host }
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
    region = @current_island.region
    region = nil if region == "—"
    infra  = @current_island.infra

    return if region.nil? && infra.nil?

    label = region && infra ? "region" : (region ? "region" : "infra")
    value =
      if region && infra
        "#{region} · #{infra}"
      else
        region || infra
      end

    chip(label, value)
  end

  def no_island_hint
    span(class: "text-voodu-muted text-xs") { "no server selected" }
  end

  # Full search box — visible at 1100+. Real button now: clicking
  # opens the command palette (or operator hits Cmd-K from anywhere).
  # The Cmd-K hint only shows at 1280+ (where there's room).
  def search_box
    button(
      type: "button",
      data: { action: "click->command-palette#open" },
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
      data: { action: "click->command-palette#open" },
      class: "vmd:hidden inline-flex items-center justify-center w-9 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2 shrink-0",
      aria: { label: "Open command palette" }
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
  # The dot still animates (pulse), signaling "this is live data."
  # The hover state on the whole anchor underlines the affordance.
  def updated_pill
    a(
      href: refresh_href,
      data: {
        controller: "updated-at",
        action: "click->updated-at#refresh",
        updated_at_iso_value: @updated_at.iso8601
      },
      title: "Click to refresh — bypasses the snapshot cache",
      class: "inline-flex items-center gap-2 px-1 vmd:px-2.5 h-8 border border-voodu-border bg-voodu-surface text-[11.5px] text-voodu-muted hover:bg-voodu-surface-2 hover:text-voodu-text shrink-0"
    ) do
      span(
        class: "inline-block rounded-full animate-voodu-pulse",
        style: "width: 6px; height: 6px; background: var(--voodu-green); box-shadow: 0 0 0 3px color-mix(in srgb, var(--voodu-green) 18%, transparent);"
      )
      span(class: "hidden vmd:inline") { "updated" }
      span(class: "font-voodu-mono text-voodu-text-2") do
        span(data: { updated_at_target: "label" }) { "now" }
        span(class: "hidden vmd:inline") { " ago" }
      end
      span(class: "inline-flex items-center justify-center w-5 h-5 text-voodu-muted") do
        render Icon::ArrowPathOutline.new(class: "w-3.5 h-3.5")
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
