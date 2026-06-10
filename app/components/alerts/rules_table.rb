# frozen_string_literal: true

# Components::Alerts::RulesTable — every rule, one row each. Rows are
# flex (not <table>) so the same markup stacks cleanly at 360px:
# status + name on the first line, condition + value next, actions
# last — and lines up as columns from `vmd:` up.
#
# Action labels hide on mobile (icons stay) — three buttons share
# the row, per the responsive checklist.
class Components::Alerts::RulesTable < Components::Base
  def initialize(rules:)
    @rules = rules
  end

  def view_template
    div(class: "border border-voodu-border bg-voodu-surface") do
      @rules.each { |rule| rule_row(rule) }
    end
  end

  private

  def rule_row(rule)
    div(
      class: "flex flex-col vmd:flex-row vmd:items-center gap-2 vmd:gap-4 px-3.5 py-3 " \
             "border-b border-voodu-border-2 last:border-b-0"
    ) do
      div(class: "flex items-center gap-2.5 flex-1 min-w-0") do
        status_badge(rule)

        div(class: "flex flex-col gap-0.5 min-w-0") do
          span(class: "text-[12.5px] font-medium text-voodu-text truncate") { rule.name }
          span(class: "text-[11px] font-voodu-mono text-voodu-muted truncate") { rule.target_label }
        end
      end

      div(class: "flex items-center gap-4 vmd:gap-5 shrink-0") do
        cell("condition") { rule.condition_label }
        cell("last") { rule.format_value(rule.last_value) }
      end

      actions_row(rule)
    end
  end

  def status_badge(rule)
    variant, label =
      if !rule.enabled?
        [:neutral, "PAUSED"]
      elsif rule.firing?
        [:danger, "FIRING"]
      elsif rule.last_status == "ok"
        [:success, "OK"]
      elsif rule.last_status == "stale"
        [:warning, "STALE"]
      else
        [:neutral, "NO DATA"]
      end

    span(class: "w-[72px] shrink-0") do
      render Components::UI::Badge.new(variant: variant, dot: variant == :danger) { label }
    end
  end

  def cell(label, &)
    div(class: "flex flex-col gap-0.5") do
      span(class: "text-[10px] uppercase tracking-[0.06em] text-voodu-muted") { label }
      span(class: "text-[12px] font-voodu-mono text-voodu-text-2 whitespace-nowrap", &)
    end
  end

  def actions_row(rule)
    div(class: "flex items-center gap-1.5 shrink-0") do
      metrics_link(rule)
      toggle_button(rule)

      render Components::UI::Button.new(
        variant: :ghost, size: :sm, tag: :a,
        href: edit_alert_rule_path(rule),
        title: "Edit rule"
      ) do
        render Icon::PencilSquareOutline.new(class: "w-3.5 h-3.5")
        span(class: "hidden vmd:inline") { "Edit" }
      end

      delete_button(rule)
    end
  end

  # Jump straight to this rule's target on /metrics — host grid or the
  # deployment's chart. Plain anchor: it sits inside the alerts-live
  # frame (target=_top), so it navigates the whole page as intended.
  def metrics_link(rule)
    render Components::UI::Button.new(
      variant: :ghost, size: :sm, tag: :a,
      href: metrics_path(rule.metrics_link_params),
      title: "Open metrics for #{rule.target_label}"
    ) do
      render Icon::ChartBarOutline.new(class: "w-3.5 h-3.5")
      span(class: "hidden vmd:inline") { "Metrics" }
    end
  end

  # Pause/resume is a plain POST — benign + instantly reversible, no
  # confirmation modal needed.
  def toggle_button(rule)
    form(action: toggle_alert_rule_path(rule), method: "post", data: { turbo: false }) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      render Components::UI::Button.new(
        variant: :ghost, size: :sm, type: :submit,
        title: rule.enabled? ? "Pause rule" : "Resume rule"
      ) do
        if rule.enabled?
          render Icon::PauseOutline.new(class: "w-3.5 h-3.5")
          span(class: "hidden vmd:inline") { "Pause" }
        else
          render Icon::PlayOutline.new(class: "w-3.5 h-3.5")
          span(class: "hidden vmd:inline") { "Resume" }
        end
      end
    end
  end

  def delete_button(rule)
    render Components::UI::Confirmable.new(
      title:         "Remove rule",
      message:       "Permanently remove \"#{rule.name}\"? Its alert history goes with it.",
      confirm_label: "Remove",
      danger:        true,
      icon:          :TrashOutline,
      form: {
        action: alert_rule_path(rule),
        method: :delete
      },
      trigger: {
        class: "inline-flex items-center gap-2 px-3 py-1.5 text-xs rounded-voodu-md " \
               "text-voodu-muted hover:text-voodu-red hover:bg-voodu-red-dim transition-colors",
        title: "Remove rule",
        "aria-label": "Remove #{rule.name}"
      }
    ) do
      render Icon::TrashOutline.new(class: "w-3.5 h-3.5")
      span(class: "hidden vmd:inline") { "Remove" }
    end
  end
end
