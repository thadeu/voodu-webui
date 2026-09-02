# frozen_string_literal: true

# Components::Activity::Table — the action trail as a list of rows grouped by
# day, newest first.
#
# NOT an HTML table, for the reason the UI checklist gives: a real table with
# eight columns cannot survive 360px, and transposing it per-breakpoint means
# maintaining the markup twice. A row that stacks (`flex-col vmd:flex-row`) is
# one structure that reads as a table on a laptop and as a card on a phone.
#
# Day grouping uses the operator's configured timezone (WebTime), so "TODAY"
# matches their wall clock rather than the server's.
class Components::Activity::Table < Components::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    list_head

    if @data.any?
      # overflow-x-auto so the column row can keep its widths on a narrow
      # laptop instead of crushing the target column; below vmd: the rows
      # stack into cards and there is nothing to scroll.
      div(class: "border border-voodu-border bg-voodu-surface overflow-x-auto") do
        div(class: "vmd:min-w-[1078px]") do
          column_head
          grouped_rows.each { |label, rows| day_group(label, rows) }
        end
      end
    else
      empty_state
    end
  end

  private

  # No total beside the label any more. It was a COUNT(*) over every match on
  # every render — and under the text search, a second scan of the whole window
  # — spent on a number that only served the "page N of M" the cursor paging
  # replaced. The page's own row count sits on the pager instead.
  def list_head
    div(class: "flex items-center gap-2 mb-2.5") do
      span(class: "text-[11px] font-semibold uppercase tracking-[0.08em] text-voodu-muted") { "Timeline" }
      span(class: "flex-1 h-px bg-voodu-border-2")
    end
  end

  # Two different empty states, because they are two different facts. Telling
  # an operator whose filters matched nothing that the server has no activity
  # sends them looking for a broken pipeline that is working fine.
  def empty_state
    div(class: "border border-voodu-border bg-voodu-surface px-3.5 py-5 flex flex-col gap-1.5") do
      case @data.empty_because
      when :filtered
        span(class: "text-[13px] text-voodu-text-2") { "No actions match these filters." }
        span(class: "text-[11.5px] text-voodu-muted") { "Widen the range or clear a filter." }
      else
        span(class: "text-[13px] text-voodu-text-2") { "Nothing recorded on this server yet." }
        span(class: "text-[11.5px] text-voodu-muted") do
          "Applies, restarts, deletes, rollbacks and config changes appear here within a minute of happening."
        end
      end
    end
  end

  # Column labels, desktop only. Below the breakpoint each row is a card and a
  # header row would label columns that are no longer side by side.
  #
  # Widths mirror Components::Activity::Row exactly; they are two halves of one
  # layout, and a change to either without the other misaligns every row.
  def column_head
    div(
      class: "hidden vmd:flex items-center gap-3 px-3.5 py-1.5 border-b border-voodu-border " \
             "text-[10px] font-semibold uppercase tracking-[0.08em] text-voodu-muted"
    ) do
      span(class: "w-[74px] shrink-0") { "Started" }
      span(class: "w-[92px] shrink-0") { "Action" }
      span(class: "w-[100px] shrink-0") { "Scope" }
      span(class: "w-[128px] shrink-0") { "App" }
      span(class: "flex-1 min-w-0") { "Target" }
      span(class: "w-[110px] shrink-0") { "Origin" }
      span(class: "w-[168px] shrink-0") { "Client" }
      span(class: "w-[54px] shrink-0 text-right") { "Took" }
      span(class: "w-[92px] shrink-0") { "Status" }
    end
  end

  def grouped_rows
    @data.rows.group_by { |row| day_label(row.started_at) }
  end

  def day_group(label, rows)
    div(class: "px-3.5 py-1.5 bg-voodu-bg-2 border-b border-voodu-border-2 text-[10px] font-semibold uppercase tracking-[0.08em] text-voodu-muted") do
      label
    end

    rows.each { |row| render Components::Activity::Row.new(row: row) }
  end

  # TODAY / YESTERDAY / weekday for the last week / date beyond that — the
  # same ladder the alert history uses, so two timelines in one product read
  # the same way.
  def day_label(time)
    local = WebTime.in_zone(time)
    today = WebTime.in_zone(Time.current).to_date
    date = local.to_date

    case today - date
    when 0 then "Today"
    when 1 then "Yesterday"
    when 2..6 then local.strftime("%A")
    else local.strftime("%b %-d, %Y")
    end.upcase
  end
end
