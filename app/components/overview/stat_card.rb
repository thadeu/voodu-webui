# frozen_string_literal: true

# Components::Overview::StatCard — one of the four big metric tiles
# on the Overview screen (CPU / Memory / Disk I/O / Network).
#
# Anatomy (matches the design beta mockup):
#
#   ┌────────────────────────────────┐
#   │ 🟪 CPU                    [1h] │   header: icon + label + period chip
#   │                                │
#   │ 41.2 %               [↑ 2.4%]  │   value + unit + change badge
#   │ 8 cores · load 3.41            │   subtext
#   │                                │
#   │     ▁▂▃▄▆▅▇▆█▅▆▇▆▅▇           │   sparkline (full width, bottom)
#   └────────────────────────────────┘
#
# `series` is the sparkline data — an Array of rich points
# `[{ts:, value:, formatted:}]` from MetricsData#points_for. Empty
# array (cold boot, controller offline, no data yet) hides the
# chart cleanly via Sparkline's `return if points.size < 2`.
class Components::Overview::StatCard < Components::Base
  def initialize(label:, icon:, value:, unit:, sub:, color:, series:, period: "1h", delta: nil)
    @label  = label
    @icon   = icon   # Heroicon constant symbol, e.g. :CpuChipOutline
    @value  = value
    @unit   = unit
    @sub    = sub
    @color  = color
    @series = series  # Array of {ts:, value:, formatted:} hashes
    @period = period
    @delta  = delta  # e.g. "↑ 2.4%" — nil hides the change badge
  end

  def view_template
    div(
      class: "flex flex-col gap-3 p-4 rounded-voodu-md border border-voodu-border bg-voodu-surface min-h-[170px]"
    ) do
      header_row
      value_row
      div(class: "flex-1 -mx-2 -mb-2") { sparkline }
    end
  end

  private

  def header_row
    div(class: "flex items-center gap-2") do
      div(
        class: "h-5 w-5 rounded-voodu-sm flex items-center justify-center",
        style: "background: color-mix(in srgb, #{@color} 12%, transparent); color: #{@color};"
      ) do
        icon_klass = Icon.const_get(@icon)
        render icon_klass.new(class: "w-3 h-3")
      end
      span(class: "text-[10.5px] font-medium uppercase tracking-wider text-voodu-muted") { @label }
      div(class: "flex-1")
      span(class: "inline-flex items-center px-1.5 h-[18px] text-[10.5px] font-medium rounded-voodu-sm border border-voodu-border text-voodu-muted") { @period }
    end
  end

  def value_row
    div(class: "flex flex-col gap-0.5") do
      div(class: "flex items-baseline gap-1.5") do
        span(class: "text-[28px] font-semibold leading-none text-voodu-text") { @value.to_s }
        span(class: "text-[11px] text-voodu-muted") { @unit }
        if @delta
          div(class: "flex-1")
          delta_badge
        end
      end
      span(class: "text-[11px] text-voodu-text-2") { @sub }
    end
  end

  def delta_badge
    span(
      class: "inline-flex items-center px-1.5 py-0.5 text-[10.5px] font-medium rounded-voodu-sm",
      style: "color: var(--voodu-green); background: var(--voodu-green-dim);"
    ) { @delta }
  end

  # sparkline — uses the SAME rendering engine as the big charts
  # on the /metrics page (Components::Metrics::Chart) just in
  # compact mode (axes hidden). This unifies the chart look across
  # Overview / Pod show / Metrics — same gradient + smooth curve
  # + hover crosshair + tooltip everywhere.
  #
  # range_ms defaults to 1h since StatCards on Overview always
  # request the 1h range from MetricsData.
  def sparkline
    return if @series.blank?

    render Components::Metrics::Chart.new(
      points:   @series,
      color:    @color,
      unit:     @unit,
      label:    @label,
      range_ms: 60 * 60 * 1000,
      height:   56,
      axes:     false
    )
  end
end
