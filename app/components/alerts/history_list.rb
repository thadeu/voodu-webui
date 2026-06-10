# frozen_string_literal: true

# Components::Alerts::HistoryList — resolved episodes, newest first.
# Rows render purely from the event's snapshot columns (rule_name,
# target_label, metric_kind, threshold) so an edited or deleted rule
# can't rewrite what actually happened.
class Components::Alerts::HistoryList < Components::Base
  def initialize(events:)
    @events = events
  end

  def view_template
    if @events.empty?
      div(class: "px-3.5 py-4 border border-voodu-border bg-voodu-surface text-[12px] text-voodu-muted") do
        "No resolved alerts yet."
      end
      return
    end

    div(class: "border border-voodu-border bg-voodu-surface") do
      @events.each { |event| event_row(event) }
    end
  end

  private

  def event_row(event)
    div(
      class: "flex flex-col vmd:flex-row vmd:items-center gap-1.5 vmd:gap-4 px-3.5 py-2.5 " \
             "border-b border-voodu-border-2 last:border-b-0"
    ) do
      div(class: "flex items-center gap-2.5 flex-1 min-w-0") do
        render Components::UI::StatusDot.new(status: :stopped, pulse: false)

        div(class: "flex flex-col gap-0 min-w-0") do
          span(class: "text-[12.5px] text-voodu-text truncate") { event.rule_name }
          span(class: "text-[11px] font-voodu-mono text-voodu-muted truncate") { event.target_label }
        end
      end

      div(class: "flex items-center gap-3 vmd:gap-4 pl-[17px] vmd:pl-0 shrink-0 text-[11.5px] text-voodu-muted") do
        span(class: "font-voodu-mono") do
          plain "peak #{event.format_value(event.peak_value)} vs #{event.format_value(event.threshold)}"
        end
        span { "lasted #{Island.humanize_uptime(event.duration_seconds)}" }
        span { "resolved #{ago(event.resolved_at)}" }
      end
    end
  end

  def ago(time)
    return "—" if time.nil?

    secs = (Time.current - time).to_i.abs

    case secs
    when 0..59        then "#{secs}s ago"
    when 60..3599     then "#{secs / 60}m ago"
    when 3600..86_399 then "#{secs / 3600}h ago"
    else                   "#{secs / 86_400}d ago"
    end
  end
end
