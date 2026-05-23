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
  def initialize(current_island: nil, islands: [], updated_at: nil)
    @current_island = current_island
    @islands        = islands
    @updated_at     = updated_at
  end

  def view_template
    header(
      class: "flex h-14 items-center gap-2.5 px-3.5 vmd:px-4 border-b border-voodu-border bg-voodu-bg flex-none",
      role: "banner"
    ) do
      hamburger
      if @current_island
        island_breadcrumb
      else
        no_island_hint
      end

      div(class: "flex-1")
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

      render Components::UI::StatusPill.new(status: @current_island.status || :stopped)

      # Chips collapse on < 1280px to keep the topbar single-line.
      span(class: "hidden vlg:contents") do
        chip("region", @current_island.region)
        chip("uptime", @current_island.uptime)
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
          a(href: "/islands", class: "block px-3 py-1.5 text-[12px] text-voodu-muted hover:bg-voodu-surface-2 hover:text-voodu-text") { "manage servers →" }
        end
      end
    end
  end

  def switcher_row(island)
    selected = island.id == @current_island.id
    form(action: "/islands/#{island.id}/select", method: "post", class: "block", data: { turbo: false }) do
      input(type: "hidden", name: "authenticity_token", value: helpers.form_authenticity_token)
      button(
        type: "submit",
        class: tokens(
          "w-full flex items-center gap-2 px-3 py-1.5 text-left text-[12px] font-voodu-mono",
          selected ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text hover:bg-voodu-surface-2"
        )
      ) do
        render Components::UI::StatusDot.new(status: island.status)
        span(class: "truncate flex-1") { island.name }
        span(class: "text-[10.5px] text-voodu-muted") { island.host }
      end
    end
  end

  def chip(label, value)
    span(class: "inline-flex items-center gap-1.5 px-2 py-[3px] border border-voodu-border bg-voodu-surface text-[11.5px] whitespace-nowrap") do
      span(class: "text-voodu-muted-2") { label }
      span(class: "font-voodu-mono text-voodu-text-2") { value }
    end
  end

  def no_island_hint
    span(class: "text-voodu-muted text-xs") { "no server selected" }
  end

  # Full search box — visible at 1100+. The Cmd-K hint only shows
  # at 1280+ (where there's room).
  def search_box
    div(
      class: "hidden vmd:flex items-center gap-2 px-2.5 h-8 border border-voodu-border bg-voodu-surface w-[260px] vlg:w-[320px] text-voodu-muted",
      role: "search"
    ) do
      render Icon::MagnifyingGlassOutline.new(class: "w-3.5 h-3.5 shrink-0")
      span(class: "text-[13px] flex-1") { "Search pods, images, logs…" }
      span(class: "hidden vlg:flex items-center gap-1") do
        render Components::UI::Kbd.new { "⌘" }
        render Components::UI::Kbd.new { "K" }
      end
    end
  end

  # Icon-only search — mobile fallback. M-future wires Cmd-K modal;
  # for now it's visual parity with the inspiration.
  def search_icon
    button(
      type: "button",
      class: "vmd:hidden inline-flex items-center justify-center w-9 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2 shrink-0",
      aria: { label: "Search" }
    ) do
      render Icon::MagnifyingGlassOutline.new(class: "w-4 h-4")
    end
  end

  # updated_pill — compact on mobile (just dot + "25s" + refresh icon);
  # full label on 1100+. Animated pulse on the dot matches inspiration.
  def updated_pill
    span(
      class: "inline-flex items-center gap-2 px-1 vmd:px-2.5 h-8 border border-voodu-border bg-voodu-surface text-[11.5px] text-voodu-muted shrink-0"
    ) do
      span(
        class: "inline-block rounded-full animate-voodu-pulse",
        style: "width: 6px; height: 6px; background: var(--voodu-green); box-shadow: 0 0 0 3px color-mix(in srgb, var(--voodu-green) 18%, transparent);"
      )
      span(class: "hidden vmd:inline") { "updated" }
      span(class: "font-voodu-mono text-voodu-text-2") do
        plain seconds_label
        span(class: "hidden vmd:inline") { " ago" }
      end
      button(
        type: "button",
        class: "inline-flex items-center justify-center w-6 h-6 text-voodu-muted hover:text-voodu-text",
        aria: { label: "Refresh now" }
      ) do
        render Icon::ArrowPathOutline.new(class: "w-3.5 h-3.5")
      end
    end
  end

  # seconds_label — "25s ago" on vd-md+, "25s" on mobile.
  def seconds_label
    return "—" unless @updated_at

    secs = (Time.current - @updated_at).to_i.abs
    secs.zero? ? "now" : "#{secs}s"
  end
end
