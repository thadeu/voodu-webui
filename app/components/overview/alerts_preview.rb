# frozen_string_literal: true

# Components::Overview::AlertsPreview — the Overview's "Alerts" summary card: the
# org's most recently configured alert rules (M3: alerts are org-level, so this
# spans every server), each row → /alerts. Header carries a "See all" link; an
# empty org shows a "create your first" CTA.
class Components::Overview::AlertsPreview < Components::Base
  def initialize(rules:)
    @rules = rules
  end

  def view_template
    div(class: "border border-voodu-border bg-voodu-surface flex flex-col min-w-0") do
      header

      if @rules.empty?
        empty_state
      else
        div(class: "flex flex-col") { @rules.each { |rule| rule_row(rule) } }
      end
    end
  end

  private

  def header
    div(class: "flex items-center justify-between gap-2 px-3.5 py-2.5 border-b border-voodu-border") do
      div(class: "flex items-center gap-2 min-w-0") do
        render Icon::BellOutline.new(class: "w-4 h-4 shrink-0 text-voodu-muted")
        h2(class: "text-[13px] font-semibold text-voodu-text") { "Alerts" }
      end

      a(href: alerts_path, class: "shrink-0 inline-flex items-center gap-1 text-[11.5px] text-voodu-link hover:underline") do
        span { "See all" }
        render Icon::ArrowRightOutline.new(class: "w-3 h-3")
      end
    end
  end

  def rule_row(rule)
    a(
      href: alerts_path,
      class: "flex items-center gap-3 px-3.5 py-2 border-b border-voodu-border-2 last:border-b-0 hover:bg-voodu-surface-2 transition-colors"
    ) do
      span(class: "shrink-0 inline-block w-1.5 h-1.5 rounded-full", style: "background: #{status_color(rule)};")

      div(class: "min-w-0 flex-1") do
        span(class: "block text-[12.5px] text-voodu-text truncate") { rule.name }
        span(class: "block text-[11px] text-voodu-muted truncate font-voodu-mono") { rule.target_label }
      end

      span(class: "shrink-0 text-[11px] text-voodu-muted-2 font-voodu-mono hidden vmd:inline") { rule.condition_label }
    end
  end

  # status_color — red while firing, muted when paused, else green (armed + ok).
  def status_color(rule)
    return "var(--voodu-red)" if rule.firing?
    return "var(--voodu-muted-2)" unless rule.enabled?

    "var(--voodu-green)"
  end

  def empty_state
    div(class: "px-3.5 py-6 flex flex-col items-center text-center gap-1.5") do
      span(class: "text-[12px] text-voodu-text-2") { "No alert rules yet" }
      a(href: new_alert_rule_path(return_to: alerts_path(tab: "rules")), class: "text-[11.5px] text-voodu-link hover:underline") { "Create your first alert" }
    end
  end
end
