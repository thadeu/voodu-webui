# frozen_string_literal: true

# Components::Metrics::ChartCard — header (label + current value +
# min/avg/max strip) + a Components::Metrics::Chart underneath.
# 2x2 grid layout on /metrics renders four of these.
#
# Visual:
#
#   ┌───────────────────────────────────────────────────────────┐
#   │ CPU  25%        min 21.9  avg 30.8  max 39.8              │
#   │ ┌───────────────────────────────────────────────────────┐ │
#   │ │ ⎯  ⎯  ⎯  ⎯  ⎯                                         │ │
#   │ │ 50  ──╮         ╭─╮                                   │ │
#   │ │ 38      ╭──────╯   ╰╮                                 │ │
#   │ │ 25      │            ╰─╮                              │ │
#   │ │ 13      │              ╰────                          │ │
#   │ │ 0.0  ──┴────────────────────                          │ │
#   │ │      05/23  05/23  05/23  05/23  05/23                │ │
#   │ └───────────────────────────────────────────────────────┘ │
#   └───────────────────────────────────────────────────────────┘
class Components::Metrics::ChartCard < Components::Base
  # current — the unaggregated "right now" value from
  # MetricsPageData (server-side latest field). When nil, falls
  # back to series.last's bucket-aggregated value. The fallback
  # only kicks in for cold-boot when the API hasn't shipped a
  # latest yet; otherwise the headline tracks the literal latest
  # sample and stays stable across range pills.
  def initialize(label:, color:, unit:, points:, range_ms:, current: nil)
    @label    = label
    @color    = color
    @unit     = unit
    @points   = Array(points)
    @range_ms = range_ms
    @current  = current
  end

  def view_template
    div(class: "bg-voodu-surface border border-voodu-border p-3.5 flex flex-col gap-2 min-w-0") do
      header
      render Components::Metrics::Chart.new(
        points:   @points,
        color:    @color,
        unit:     @unit,
        label:    @label,
        range_ms: @range_ms,
        height:   200
      )
    end
  end

  private

  # header — colored label + big current value + right-aligned
  # min/avg/max strip. Matches pages-metrics.jsx ChartCard
  # (lines 358-398) layout.
  #
  # Headline current value preference order:
  #   1. @current — set explicitly by the caller from the API's
  #                 unaggregated `latest` field. Stable across
  #                 range pills (the whole point).
  #   2. series.last value — bucket-aggregated; only used when
  #                 the API didn't ship a latest (cold boot or
  #                 older controller).
  def header
    s = stats

    div(class: "flex items-baseline flex-wrap gap-2.5") do
      span(
        class: "text-[11.5px] font-semibold uppercase tracking-[0.05em]",
        style: "color: #{@color};"
      ) { @label }

      span(class: "font-voodu-mono text-[22px] font-semibold text-voodu-text") do
        plain format_current(@current || s[:current])
        span(class: "text-voodu-muted text-[12px] font-normal ml-0.5") { @unit }
      end

      div(class: "flex-1")

      stat_chip("min", s[:min])
      stat_chip("avg", s[:avg])
      stat_chip("max", s[:max])
    end
  end

  def stat_chip(label, value)
    span(class: "text-[11px] font-voodu-mono text-voodu-muted") do
      plain "#{label} "
      span(class: "text-voodu-text-2") { format_value(value) }
    end
  end

  # format_current — always 1 decimal, regardless of unit. The
  # inspiration's `toFixed(meta.unit === '%' ? 0 : 1)` shortcut
  # rounded CPU% to whole numbers, which hid sub-1% activity
  # (a pod at 0.1% read as "0%" in the headline while the tooltip
  # correctly showed 0.1%). Operator prefers consistent precision.
  def format_current(v)
    return "—" if v.nil?

    v.round(1).to_s
  end

  def format_value(v)
    return "—" if v.nil?

    v.round(1).to_s
  end

  # stats — current/min/avg/max in one pass over the series. Same
  # shape the inspiration computes in `stats()` (line 350-355).
  def stats
    return { min: nil, max: nil, avg: nil, current: nil } if @points.empty?

    values  = @points.map { |p| p[:value].to_f }
    sum     = values.sum
    current = values.last

    {
      min:     values.min,
      max:     values.max,
      avg:     sum / values.size,
      current: current
    }
  end
end
