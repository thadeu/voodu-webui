# frozen_string_literal: true

# Components::Alerts::FiringCard — one open episode, red-tinted. The
# left side identifies WHAT is wrong (rule + target), the right side
# quantifies it (current / peak vs threshold) — an operator glancing
# at the page should get both in under a second.
class Components::Alerts::FiringCard < Components::Base
  def initialize(event:)
    @event = event
  end

  def view_template
    div(
      class: "flex flex-col vmd:flex-row vmd:items-center gap-2 vmd:gap-4 px-3.5 py-3 " \
             "border border-voodu-red/45 border-l-[3px] border-l-voodu-red bg-voodu-red-dim"
    ) do
      identity_block
      values_block
    end
  end

  private

  def identity_block
    div(class: "flex items-start gap-2.5 flex-1 min-w-0") do
      span(class: "mt-1") { render Components::UI::StatusDot.new(status: :error, pulse: true) }

      div(class: "flex flex-col gap-0.5 min-w-0") do
        div(class: "text-[13px] font-semibold text-voodu-text") { @event.rule_name }
        div(class: "text-[11.5px] font-voodu-mono text-voodu-text-2 truncate") { @event.target_label }
        div(class: "text-[11.5px] text-voodu-muted") do
          plain "firing for #{Island.humanize_uptime(@event.duration_seconds)}"
          plain " · started #{ago(@event.started_at)}"
        end
        metrics_link
      end
    end
  end

  # Small inline link under the firing meta — jump to the target's
  # chart on /metrics. Reads the live rule (includes-loaded in
  # AlertsPageData#firing_events) for the target; the event only
  # snapshots a label string. Falls back to the bare metrics page if
  # the rule is somehow gone.
  def metrics_link
    rule = @event.alert_rule
    href = rule ? metrics_path(rule.metrics_link_params) : metrics_path

    a(
      href:  href,
      title: "Open metrics for #{@event.target_label}",
      class: "inline-flex items-center gap-1 mt-1.5 w-fit px-2 h-6 text-[11px] " \
             "bg-voodu-surface text-voodu-text border border-voodu-border " \
             "hover:bg-voodu-surface-2 transition-colors"
    ) do
      render Icon::ChartBarOutline.new(class: "w-3 h-3 shrink-0")
      span { "Open metrics" }
    end
  end

  def values_block
    div(class: "flex items-center gap-4 vmd:gap-5 pl-[21px] vmd:pl-0 shrink-0") do
      value_cell("now",  @event.format_value(@event.last_value), strong: true)
      value_cell("peak", @event.format_value(@event.peak_value))
      value_cell("threshold", "#{comparator_symbol} #{@event.format_value(@event.threshold)}")
    end
  end

  def value_cell(label, value, strong: false)
    div(class: "flex flex-col gap-0.5") do
      span(class: "text-[10px] uppercase tracking-[0.06em] text-voodu-muted") { label }
      span(
        class: tokens(
          "text-[13px] font-voodu-mono",
          strong ? "text-voodu-red font-semibold" : "text-voodu-text-2"
        )
      ) { value }
    end
  end

  # The comparator wasn't snapshotted on the event (threshold +
  # labels were); read it through the live rule and fall back to ≥ —
  # the overwhelmingly common direction — if the rule is gone.
  def comparator_symbol
    @event.alert_rule&.comparator_symbol || "≥"
  rescue ActiveRecord::RecordNotFound
    "≥"
  end

  def ago(time)
    secs = (Time.current - time).to_i.abs

    case secs
    when 0..59        then "#{secs}s ago"
    when 60..3599     then "#{secs / 60}m ago"
    when 3600..86_399 then "#{secs / 3600}h ago"
    else                   "#{secs / 86_400}d ago"
    end
  end
end
