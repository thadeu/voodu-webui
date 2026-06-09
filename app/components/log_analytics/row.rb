# frozen_string_literal: true

# Components::LogAnalytics::Row — one line in the analytics results
# table (and reused inside the Surrounding Logs modal). Native
# <details>/<summary> drives expand/collapse with zero JS: the summary
# is the collapsed line (chevron + timestamp + message), the panel below
# carries the structured fields + raw payload + the "Surrounding logs"
# drill-in.
#
# Per-level left-border tint follows the project's chart palette rule:
# --voodu-red is reserved for errors/failures, amber for warnings, blue
# for info, muted for debug/trace + unparsed lines.
#
#   row:          { ts:, pod:, stream:, level:, msg:, raw:, parsed: }
#   surroundable: render the "Surrounding logs" drill-in (true in the
#                 results table; false inside the surrounding modal so
#                 it doesn't recurse).
#   anchor:       highlight this row as the surrounding-modal anchor +
#                 mark it so the controller scrolls it into view.
class Components::LogAnalytics::Row < Components::Base
  def initialize(row:, surroundable: true, anchor: false)
    @row          = row
    @surroundable = surroundable
    @anchor       = anchor
  end

  def view_template
    details(
      class: tokens(
        "group la-row block border-b border-voodu-border/60",
        @anchor ? "bg-voodu-accent-dim" : "hover:bg-voodu-surface/60"
      ),
      style: "border-left: 2px solid #{level_color};",
      data: (@anchor ? { surrounding_anchor: "true" } : {})
    ) do
      summary_row
      detail_panel
    end
  end

  private

  def summary_row
    summary(
      class: tokens(
        "flex flex-col vmd:flex-row vmd:items-baseline gap-1 vmd:gap-3",
        "px-2.5 py-1.5 cursor-pointer list-none select-none",
        "font-voodu-mono text-[11.5px] leading-relaxed"
      )
    ) do
      div(class: "flex items-baseline gap-2 shrink-0") do
        render Icon::ChevronRightOutline.new(
          class: "w-3 h-3 mt-0.5 text-voodu-muted-2 shrink-0 transition-transform group-open:rotate-90"
        )
        level_chip
        time(class: "text-voodu-muted whitespace-nowrap") { @row[:ts] }
      end

      span(class: "text-voodu-log-payload truncate min-w-0") do
        @row[:msg].presence || @row[:raw]
      end
    end
  end

  def detail_panel
    div(class: "px-2.5 pb-3 pt-1 vmd:pl-[26px] flex flex-col gap-2.5") do
      field_grid
      raw_block
      row_actions
    end
  end

  # field_grid — the parsed envelope (time / pod / stream / level) as a
  # compact key/value strip. Mirrors CloudWatch's expanded-row fields.
  def field_grid
    div(class: "flex flex-wrap gap-x-5 gap-y-1.5 text-[11px] font-voodu-mono") do
      field("@timestamp", @row[:ts])
      field("@pod",       @row[:pod])
      field("@stream",    @row[:stream].presence || "stdout")
      field("@level",     @row[:level].presence || "—")
    end
  end

  def field(key, value)
    div(class: "flex flex-col gap-0.5 min-w-0") do
      span(class: "text-voodu-muted-2 uppercase tracking-wide text-[9.5px]") { key }
      span(class: "text-voodu-text-2 break-all") { value.to_s }
    end
  end

  def raw_block
    pre(
      class: tokens(
        "m-0 px-2.5 py-2 bg-voodu-bg border border-voodu-border",
        "font-voodu-mono text-[11px] leading-relaxed text-voodu-log-payload",
        "whitespace-pre-wrap break-words overflow-x-auto"
      )
    ) { @row[:raw].presence || @row[:msg] }
  end

  def row_actions
    div(class: "flex items-center gap-1.5 flex-wrap") do
      copy_button
      surrounding_button if @surroundable
    end
  end

  def copy_button
    button(
      type:  "button",
      title: "Copy raw line",
      data:  { action: "click->log-analytics#copyLine", raw: @row[:raw].presence || @row[:msg] },
      class: action_btn_classes
    ) do
      render Icon::ClipboardOutline.new(class: "w-3 h-3")
      span(class: "hidden vmd:inline") { "Copy" }
    end
  end

  # surrounding_button — opens the Surrounding Logs modal anchored on
  # this exact line. Carries the raw ts + pod so the server can locate
  # the anchor; the log-analytics controller fetches + injects the modal.
  def surrounding_button
    button(
      type:  "button",
      title: "Show surrounding logs",
      data:  {
        action: "click->log-analytics#openSurrounding",
        ts:     @row[:ts],
        pod:    @row[:pod]
      },
      class: action_btn_classes
    ) do
      render Icon::ArrowsPointingOutOutline.new(class: "w-3 h-3")
      span(class: "hidden vmd:inline") { "Surrounding logs" }
    end
  end

  def action_btn_classes
    tokens(
      "inline-flex items-center gap-1.5 px-2 h-6 border border-voodu-border bg-voodu-surface",
      "text-[10.5px] font-medium text-voodu-text-2",
      "hover:bg-voodu-surface-2 hover:text-voodu-text transition-colors"
    )
  end

  def level_chip
    lvl = @row[:level].to_s
    return if lvl.blank?

    span(
      class: "inline-flex items-center px-1.5 h-4 text-[9.5px] font-bold tracking-wider shrink-0",
      style: "color: #{level_color}; background: color-mix(in srgb, #{level_color} 14%, transparent);"
    ) { lvl }
  end

  # level_color — the chart-palette tint for this row's level.
  # --voodu-red stays reserved for errors/failures (CLAUDE.md rule).
  def level_color
    case @row[:level].to_s.upcase
    when "ERROR", "FATAL"  then "var(--voodu-red)"
    when "WARN", "WARNING" then "var(--voodu-amber)"
    when "INFO"            then "var(--voodu-blue)"
    when "DEBUG", "TRACE"  then "var(--voodu-muted)"
    else                        "var(--voodu-border-2)"
    end
  end
end
