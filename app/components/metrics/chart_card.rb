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
  #
  # expand_url: STRING → enables the "maximize" button in the
  # header that opens an overlay modal containing the same chart
  # at a much larger render size + a local-scoped range picker.
  # Caller (Views::Metrics::Index#render_chart_cards) builds the
  # URL via metrics_chart_path with metric/source/scale
  # baked in. Pass nil (or omit) to render a maximize-less card —
  # used historically by call sites that don't have access to the
  # full single-chart context; safe default.
  def initialize(label:, color:, unit:, points:, range_ms:, current: nil, expand_url: nil)
    @label      = label
    @color      = color
    @unit       = unit
    @points     = Array(points)
    @range_ms   = range_ms
    @current    = current
    @expand_url = expand_url
  end

  def view_template
    # When expand_url is set, the wrapping div hosts the
    # chart-expand controller, the maximize button, and the
    # hidden overlay scaffold. Without expand_url, falls back to
    # the previous shape so existing call sites stay unchanged.
    if @expand_url
      div(
        data: {
          controller: "chart-expand",
          chart_expand_src_value: @expand_url
        },
        class: "bg-voodu-surface border border-voodu-border p-3.5 flex flex-col gap-2 min-w-0 relative group"
      ) do
        card_header
        render Components::Metrics::Chart.new(
          points:   @points,
          color:    @color,
          unit:     @unit,
          label:    @label,
          range_ms: @range_ms,
          height:   200
        )
        overlay_modal
      end
    else
      div(class: "bg-voodu-surface border border-voodu-border p-3.5 flex flex-col gap-2 min-w-0") do
        card_header
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
  end

  private

  # card_header — colored label + big current value + right-aligned
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
  #
  # Named `card_header` (not `header`) because `header` is also
  # a Phlex HTML tag — Phlex's method_missing for HTML tags
  # collides with this method name if we ever try to use the
  # actual `<header>` tag in the same component (the overlay_modal
  # below does exactly that).
  def card_header
    s = stats

    div(class: "flex items-baseline flex-wrap gap-2.5") do
      span(
        class: "text-[11.5px] font-semibold uppercase tracking-[0.05em]",
        style: "color: #{@color};"
      ) { @label }

      # Render number + unit. For percent metrics the unit is part
      # of the formatted string (so we can show "<0.01%" without
      # the magnitude tier rendering "<0.01" with a separate "%"
      # span looking like "<0.01 %"). For everything else the
      # number stays plain and the unit hangs in its own muted
      # span.
      span(class: "font-voodu-mono text-[22px] font-semibold text-voodu-text") do
        if percent_unit?
          plain format_current(@current || s[:current])
        else
          plain format_current(@current || s[:current])
          span(class: "text-voodu-muted text-[12px] font-normal ml-0.5") { @unit }
        end
      end

      div(class: "flex-1")

      stat_chip("min", s[:min])
      stat_chip("avg", s[:avg])
      stat_chip("max", s[:max])

      maximize_button if @expand_url
    end
  end

  # maximize_button — opens the overlay modal with the same chart
  # rendered taller + an isolated range picker. Sits next to the
  # min/avg/max strip so it's discoverable without dominating the
  # header. `group-hover` would be nice (CloudWatch only shows the
  # icon on hover) but Phlex doesn't make that any cleaner than
  # always-visible; muted color keeps it from competing visually.
  def maximize_button
    button(
      type: "button",
      data: { action: "chart-expand#open" },
      title: "Expand chart",
      "aria-label": "Expand #{@label} chart",
      class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 shrink-0"
    ) do
      render Icon::ArrowsPointingOutOutline.new(class: "w-3.5 h-3.5")
    end
  end

  # overlay_modal — the in-page modal that pops up on maximize.
  # Hidden by default; chart_expand_controller removes the `hidden`
  # attr + sets the turbo-frame's `src` on open. Backdrop click +
  # X button + ESC all close.
  #
  # NOT using Components::UI::Modal because that one is built for
  # full-page routes (open via navigation, close via navigation).
  # This is an OVERLAY: opens client-side on the current page, no
  # URL change. Same shadow/blur language though, so visual parity.
  def overlay_modal
    div(
      data: { chart_expand_target: "overlay" },
      hidden: true,
      class: "fixed inset-0 z-[65] flex items-center justify-center"
    ) do
      # backdrop
      div(
        "aria-hidden": "true",
        data: { action: "click->chart-expand#backdropClick" },
        class: "absolute inset-0 bg-black/55 backdrop-blur-[3px]"
      )

      # dialog
      div(
        role: "dialog",
        "aria-modal": "true",
        "aria-label": "#{@label} chart",
        class: tokens(
          "relative z-[1]",
          "w-[min(1100px,calc(100vw-32px))] max-h-[calc(100vh-48px)]",
          "flex flex-col min-h-0",
          "bg-voodu-surface-2 border border-voodu-border-2",
          "shadow-[0_28px_56px_rgba(0,0,0,0.65),0_4px_12px_rgba(0,0,0,0.4)]"
        )
      ) do
        # header
        header(
          class: "flex items-center gap-2.5 px-4 py-3 border-b border-voodu-border bg-voodu-surface"
        ) do
          h2(
            class: "m-0 text-[13px] font-semibold uppercase tracking-[0.05em] font-voodu-mono",
            style: "color: #{@color};"
          ) { @label }
          div(class: "flex-1")
          button(
            type: "button",
            "aria-label": "Close",
            data: { action: "click->chart-expand#close" },
            class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2"
          ) { render Icon::XMarkOutline.new(class: "w-3.5 h-3.5") }
        end

        # body — turbo-frame placeholder. chart_expand_controller
        # sets `src` on open, Turbo fetches /metrics/chart and
        # injects the response inside. Range pills inside the
        # frame body re-target the same frame for in-place
        # navigation without closing the modal.
        div(class: "flex flex-col overflow-auto min-h-0") do
          turbo_frame_tag("chart-modal-frame", data: { chart_expand_target: "frame" }) do
            # Initial loading placeholder. Replaced by the /metrics/chart
            # response on open; Turbo extracts the matching frame from
            # the response and swaps the contents.
            div(class: "p-6 text-voodu-muted text-[12px] text-center") { "Loading chart…" }
          end
        end
      end
    end
  end

  def stat_chip(label, value)
    span(class: "text-[11px] font-voodu-mono text-voodu-muted") do
      plain "#{label} "
      span(class: "text-voodu-text-2") { format_value(value) }
    end
  end

  # format_current — magnitude-adaptive headline. Percent metrics
  # go through MetricFormat.percent so sub-1% values keep enough
  # precision to be honest (0.05% instead of "0.0%"); other
  # metrics use MetricFormat.number (the unit hangs in a separate
  # muted span — see header).
  def format_current(v)
    return "—" if v.nil?

    percent_unit? ? MetricFormat.percent(v) : MetricFormat.number(v)
  end

  # format_value — min/avg/max chips. Same logic as format_current
  # so the headline + chips agree on precision (no more "current 0.0
  # · avg 0.0 · max 0.0" lying about a chart that clearly varies).
  def format_value(v)
    return "—" if v.nil?

    percent_unit? ? MetricFormat.percent(v) : MetricFormat.number(v)
  end

  # percent_unit? — whether the headline + chip formatters should
  # bake the `%` into the formatted string. True only for actual
  # percent units; "MB"/"GB"/"" stay number-only with the unit
  # rendered in its own span.
  def percent_unit?
    @unit == "%"
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
