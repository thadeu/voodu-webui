# frozen_string_literal: true

# Components::Layouts::Topbar — 48px header above content.
#
# Left side
#   - breadcrumb (islands › <name>)
#   - StatusPill for the active island
#   - dropdown to switch islands (when more than one is registered)
#   - host chip
#
# Right side
#   - search (⌘K hint, M-future wires it)
#   - "Add island" CTA
#
# When no island is selected, left collapses to a single hint;
# right still shows the CTA so onboarding is always one click away.
class Components::Layouts::Topbar < Components::Base
  def initialize(current_island: nil, islands: [])
    @current_island = current_island
    @islands        = islands
  end

  def view_template
    header(
      class: "flex h-12 items-center gap-3 px-4 border-b border-voodu-border bg-voodu-bg-2",
      role: "banner"
    ) do
      if @current_island
        island_breadcrumb
      else
        no_island_hint
      end

      div(class: "flex-1")
      search_box
      add_island_btn
    end
  end

  private

  def island_breadcrumb
    div(class: "flex items-center gap-3 min-w-0") do
      # Breadcrumb with optional dropdown trigger.
      div(class: "flex items-center gap-1.5 min-w-0") do
        span(class: "text-voodu-muted text-xs") { "islands" }
        render Icon::ChevronRightOutline.new(class: "w-2.5 h-2.5 text-voodu-muted")

        if @islands.size > 1
          island_switcher
        else
          span(class: "font-voodu-mono text-sm font-medium text-voodu-text truncate") { @current_island.name }
        end
      end

      render Components::UI::StatusPill.new(status: @current_island.status || :stopped)
      chip("host", @current_island.host)
    end
  end

  # island_switcher — when more than one island is registered, the
  # breadcrumb's island name becomes a clickable dropdown listing all
  # registered islands. Each entry is a POST form to /islands/:id/select
  # (keeps switching CSRF-safe).
  def island_switcher
    div(class: "relative", data: { controller: "dropdown" }) do
      button(
        type: "button",
        class: "inline-flex items-center gap-1 font-voodu-mono text-sm font-medium text-voodu-text hover:text-voodu-accent-2",
        data: { action: "click->dropdown#toggle" }
      ) do
        span(class: "truncate") { @current_island.name }
        render Icon::ChevronDownOutline.new(class: "w-3 h-3 text-voodu-muted")
      end

      div(
        hidden: true,
        data: { dropdown_target: "menu" },
        class: "absolute left-0 top-full mt-1 min-w-[240px] z-40 rounded-voodu-md border border-voodu-border bg-voodu-surface shadow-2xl"
      ) do
        div(class: "py-1") do
          @islands.each { |i| switcher_row(i) }
        end
        div(class: "border-t border-voodu-border py-1") do
          a(href: "/islands", class: "block px-3 py-1.5 text-[12px] text-voodu-muted hover:bg-voodu-surface-2 hover:text-voodu-text") { "manage islands →" }
        end
      end
    end
  end

  def switcher_row(island)
    selected = island.id == @current_island.id
    form(
      action: "/islands/#{island.id}/select", method: "post",
      class: "block", data: { turbo: false }
    ) do
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
    span(class: "inline-flex items-center gap-1.5 px-2 py-0.5 rounded-voodu-sm border border-voodu-border bg-voodu-surface text-[11px]") do
      span(class: "text-voodu-muted-2") { label }
      span(class: "font-voodu-mono text-voodu-text-2") { value }
    end
  end

  def no_island_hint
    span(class: "text-voodu-muted text-xs") { "no island selected" }
  end

  def search_box
    div(
      class: "flex items-center gap-2 px-2.5 h-7 rounded-voodu-sm border border-voodu-border bg-voodu-surface w-[260px] text-voodu-muted",
      role: "search"
    ) do
      render Icon::MagnifyingGlassOutline.new(class: "w-3 h-3 shrink-0")
      span(class: "text-[12px] flex-1") { "search" }
      div(class: "flex items-center gap-1") do
        render Components::UI::Kbd.new { "⌘" }
        render Components::UI::Kbd.new { "K" }
      end
    end
  end

  def add_island_btn
    a(
      href: "/islands/new",
      class: "inline-flex items-center gap-1.5 px-3 h-7 rounded-voodu-sm bg-voodu-accent text-white text-[12px] font-medium hover:bg-voodu-accent-2"
    ) do
      render Icon::PlusOutline.new(class: "w-3 h-3")
      span { "Add island" }
    end
  end
end
