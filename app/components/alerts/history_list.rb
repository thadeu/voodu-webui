# frozen_string_literal: true

# Components::Alerts::HistoryList — resolved episodes as a timeline
# grouped by day (TODAY / YESTERDAY / weekday / date), newest first.
# Each row renders purely from the event's snapshot columns so an
# edited or deleted rule can't rewrite what actually happened.
#
# Day grouping uses the operator's configured timezone (WebTime), so
# "TODAY" matches their wall clock, not the server's.
class Components::Alerts::HistoryList < Components::Base
  def initialize(events:, total: nil, truncated: false)
    @events = events
    @total = total || events.size
    @truncated = truncated
  end

  def view_template
    timeline_head

    if @events.empty?
      empty_row
    else
      div(class: "border border-voodu-border bg-voodu-surface") do
        grouped_events.each { |label, events| day_group(label, events) }
      end
      truncation_note if @truncated
    end
  end

  private

  def timeline_head
    div(class: "flex items-center gap-2 mb-2.5") do
      span(class: "text-[11px] font-semibold uppercase tracking-[0.08em] text-voodu-muted") { "Timeline" }
      span(class: "text-[11px] font-voodu-mono text-voodu-muted-2") { @total.to_s }
      span(class: "flex-1 h-px bg-voodu-border-2")
    end
  end

  def empty_row
    div(class: "px-3.5 py-4 border border-voodu-border bg-voodu-surface text-[12px] text-voodu-muted") do
      "No resolved alerts in this range."
    end
  end

  def truncation_note
    div(class: "px-1 pt-2 text-[11px] text-voodu-muted") do
      "Showing the most recent #{@events.size} of #{@total} — narrow the range to see older incidents."
    end
  end

  # day_group — a day divider + the rows under it.
  def day_group(label, events)
    div(class: "px-3.5 py-1.5 bg-voodu-bg-2 border-b border-voodu-border-2 text-[10px] font-semibold uppercase tracking-[0.08em] text-voodu-muted") do
      label
    end
    events.each { |event| event_row(event) }
  end

  def event_row(event)
    div(
      class: "flex flex-col vmd:flex-row vmd:items-center gap-1.5 vmd:gap-4 px-3.5 py-2.5 " \
             "border-b border-voodu-border-2 last:border-b-0"
    ) do
      div(class: "flex items-center gap-2.5 flex-1 min-w-0") do
        span(class: "font-voodu-mono text-[11.5px] text-voodu-muted-2 w-10 shrink-0") { clock(event.resolved_at) }

        div(class: "flex flex-col gap-0 min-w-0") do
          div(class: "flex items-baseline gap-2 min-w-0") do
            span(class: "text-[12.5px] font-medium text-voodu-text truncate") { event.rule_name }
            span(class: "text-[11px] font-voodu-mono text-voodu-muted truncate") { event.target_label }
          end
          span(class: "text-[11px] text-voodu-muted") do
            "peak #{event.format_value(event.peak_value)} vs #{event.format_value(event.threshold)} · lasted #{Server.humanize_uptime(event.duration_seconds)}"
          end
        end
      end

      div(class: "flex items-center gap-2 pl-[42px] vmd:pl-0 shrink-0") do
        span(class: "text-[11.5px]", style: "color: var(--voodu-green);") { "resolved" }
        span(class: "text-[11px] text-voodu-muted-2") { "· #{ago(event.resolved_at)}" }
      end
    end
  end

  # grouped_events — Array of [day_label, events] preserving the
  # newest-first order the query already applied.
  def grouped_events
    @events.group_by { |e| day_label(e.resolved_at) }
  end

  def day_label(time)
    z = WebTime.in_zone(time)
    return "—" if z.nil?

    today = WebTime.in_zone(Time.current).to_date
    date = z.to_date
    diff = (today - date).to_i

    case diff
    when 0 then "Today"
    when 1 then "Yesterday"
    when 2..6 then z.strftime("%A")
    else z.strftime("%b %-d, %Y")
    end
  end

  def clock(time)
    WebTime.strftime(time, "%H:%M") || "—"
  end

  def ago(time)
    return "—" if time.nil?

    secs = (Time.current - time).to_i.abs

    case secs
    when 0..59 then "#{secs}s ago"
    when 60..3599 then "#{secs / 60}m ago"
    when 3600..86_399 then "#{secs / 3600}h ago"
    else "#{secs / 86_400}d ago"
    end
  end
end
