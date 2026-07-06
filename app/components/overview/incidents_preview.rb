# frozen_string_literal: true

# Components::Overview::IncidentsPreview — the Overview's "Recent incidents" card:
# the org's most recent alert episodes (firing/resolved), across every server
# (M3: alerts are org-level). Complements AlertsPreview — that shows what's
# CONFIGURED, this shows what actually FIRED. Full-width so it can carry the
# extra columns (peak value + when). Empty org → an "all quiet" state.
class Components::Overview::IncidentsPreview < Components::Base
  def initialize(events:)
    @events = events
  end

  def view_template
    div(class: "border border-voodu-border bg-voodu-surface flex flex-col min-w-0") do
      header

      if @events.empty?
        empty_state
      else
        div(class: "flex flex-col") { @events.each { |event| event_row(event) } }
      end
    end
  end

  private

  def header
    div(class: "flex items-center justify-between gap-2 px-3.5 py-2.5 border-b border-voodu-border") do
      div(class: "flex items-center gap-2 min-w-0") do
        render Icon::BoltOutline.new(class: "w-4 h-4 shrink-0 text-voodu-muted")
        h2(class: "text-[13px] font-semibold text-voodu-text") { "Recent incidents" }
      end

      a(href: alerts_path(tab: "history"), class: "shrink-0 inline-flex items-center gap-1 text-[11.5px] text-voodu-link hover:underline") do
        span { "See all" }
        render Icon::ArrowRightOutline.new(class: "w-3 h-3")
      end
    end
  end

  def event_row(event)
    firing = event.firing?

    a(
      href: alerts_path(tab: firing ? "active" : "history"),
      class: "flex items-center gap-3 px-3.5 py-2 border-b border-voodu-border-2 last:border-b-0 hover:bg-voodu-surface-2 transition-colors"
    ) do
      state_pill(firing)

      div(class: "min-w-0 flex-1") do
        span(class: "block text-[12.5px] text-voodu-text truncate") { event.rule_name }
        span(class: "block text-[11px] text-voodu-muted truncate font-voodu-mono") { event.target_label }
      end

      span(class: "shrink-0 text-[11px] text-voodu-muted-2 font-voodu-mono hidden vmd:inline") do
        "peak #{event.format_value(event.peak_value || event.last_value)}"
      end

      span(class: "shrink-0 text-[11px] text-voodu-muted-2 w-[70px] text-right") { "#{time_ago_in_words(event.started_at)} ago" }
    end
  end

  # state_pill — red "firing" while the episode is open, a muted "resolved"
  # once it closed. The dot mirrors the alerts-page FiringCard convention.
  def state_pill(firing)
    classes = firing ? "border-voodu-red/40 bg-voodu-red-dim text-voodu-red" : "border-voodu-border bg-voodu-surface-2 text-voodu-muted"

    span(class: tokens("shrink-0 inline-flex items-center gap-1.5 px-2 h-5 border text-[10px] uppercase tracking-[0.04em] w-[74px]", classes)) do
      span(class: "inline-block w-1.5 h-1.5 rounded-full", style: "background: #{firing ? "var(--voodu-red)" : "var(--voodu-muted-2)"};")
      span { firing ? "firing" : "resolved" }
    end
  end

  def empty_state
    div(class: "px-3.5 py-6 flex flex-col items-center text-center gap-1") do
      span(class: "text-[12px] text-voodu-text-2") { "No incidents yet" }
      span(class: "text-[11px] text-voodu-muted") { "Alerts that fire will show up here." }
    end
  end
end
