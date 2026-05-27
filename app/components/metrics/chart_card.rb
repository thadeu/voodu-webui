# frozen_string_literal: true

# Components::Metrics::ChartCard — header (label + current value +
# min/avg/max strip + maximize button) + a Components::Metrics::Chart
# underneath. 2x2 grid layout on /metrics renders four of these per
# resource and per HTTP scope.
#
# Visual:
#
#   ┌───────────────────────────────────────────────────────────┐
#   │ CPU  25%        min 21.9  avg 30.8  max 39.8  ⛶          │
#   │ ┌───────────────────────────────────────────────────────┐ │
#   │ │ chart …                                                │ │
#   │ └───────────────────────────────────────────────────────┘ │
#   └───────────────────────────────────────────────────────────┘
#
# Maximize (⛶) opens a SHARED modal (see Components::Metrics::ChartModal)
# rendered once at the bottom of Views::Metrics::Index. The button
# is just an anchor with `data-turbo-stream="true"`; clicking it
# sends an Accept: text/vnd.turbo-stream.html GET to /metrics/chart,
# whose response targets the modal's slots
# (#chart-modal-title + #chart-modal-body) and invokes the custom
# chart_modal_open Turbo Stream action. No per-card overlay, no
# Stimulus controller for open/close — server drives the whole
# lifecycle via turbo_stream actions.
class Components::Metrics::ChartCard < Components::Base
  # current — the unaggregated "right now" value from
  # MetricsPageData (server-side latest field). When nil, falls
  # back to series.last's bucket-aggregated value. The fallback
  # only kicks in for cold-boot when the API hasn't shipped a
  # latest yet; otherwise the headline tracks the literal latest
  # sample and stays stable across range pills.
  #
  # expand_url: STRING → enables the maximize button. Caller
  # (Views::Metrics::Index#render_chart_cards) builds the URL via
  # metrics_chart_path with metric/source/scale baked in. Pass nil
  # (or omit) to render a maximize-less card — used historically
  # by call sites that don't have access to the full single-chart
  # context; safe default.
  # metric: STRING — the metric key (e.g. "cpu_percent"). When given,
  # the root div gains data-metrics-display-target="card" +
  # data-metric-key="<metric>" so MetricsDisplayController can hide/
  # show this card based on the operator's display settings.
  # Pass nil (or omit) to opt out of the display-filter system
  # (e.g. standalone chart cards outside the main grid).
  #
  # section: STRING — "resource" or "http". When "http", a small
  # inline [http] badge renders next to the metric label, giving
  # operators a visual cue that the card is HTTP-derived. (The
  # divider-style HTTP section header was removed in favor of this
  # inline tag — fewer hard breaks in the grid, same signal.)
  #
  # default_visible: BOOLEAN — when false, the card emits
  # data-default-visible="false". The metrics-display controller
  # reads this on first connect for a kind that has no saved
  # display settings yet and hides the card by default. Operator
  # can un-hide it via the Settings drawer's Latency / Errors
  # picker groups.
  # capacity_label: STRING — "39 GB" / "512 MB" / etc. When given,
  # the headline grows a "/ <capacity_label> · NN%" suffix so the
  # card reads "21.9 GB / 39 GB · 56%" — mirrors the Overview's
  # Memory/Disk cards. Pass nil for metrics with no natural total
  # (CPU %, HTTP counts, network rates).
  # capacity_pct: NUMBER — integer percentage paired with the label.
  # Always renders alongside capacity_label; nil when the current
  # sample is missing (we omit the "· NN%" trail in that case).
  def initialize(label:, color:, unit:, points:, range_ms:, current: nil, expand_url: nil, metric: nil, section: nil, default_visible: true, capacity_label: nil, capacity_pct: nil)
    @label           = label
    @color           = color
    @unit            = unit
    @points          = Array(points)
    @range_ms        = range_ms
    @current         = current
    @expand_url      = expand_url
    @metric          = metric
    @section         = section
    @default_visible = default_visible
    @capacity_label  = capacity_label
    @capacity_pct    = capacity_pct
  end

  def view_template
    root_data = {}

    if @metric
      root_data[:metrics_display_target] = "card"
      root_data[:metric_key]             = @metric
    end

    root_data[:section]         = @section if @section
    root_data[:default_visible] = "false"  unless @default_visible

    div(
      class: "bg-voodu-surface border border-voodu-border p-3.5 flex flex-col gap-2 min-w-0",
      data:  root_data
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
    end
  end

  private

  # card_header — colored label + big current value + right-aligned
  # min/avg/max strip + maximize affordance.
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
  # collides with this method name.
  def card_header
    s = stats

    div(class: "flex items-baseline flex-wrap gap-2.5") do
      span(
        class: "text-[11.5px] font-semibold uppercase tracking-[0.05em]",
        style: "color: #{@color};"
      ) { @label }

      # [http] inline badge — replaces the old HTTP section divider.
      # Same visual signal ("this metric comes from ingress logs") but
      # without splitting the grid into two boxes.
      if @section == "http"
        span(
          class: "text-[9.5px] font-voodu-mono text-voodu-muted-2 uppercase tracking-[0.06em] " \
                 "border border-voodu-border px-1 py-px translate-y-[-1px]",
          title: "HTTP metric (ingress)"
        ) { "http" }
      end

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

      capacity_chip if @capacity_label

      div(class: "flex-1")

      stat_chip("min", s[:min])
      stat_chip("avg", s[:avg])
      stat_chip("max", s[:max])

      maximize_link if @expand_url
    end
  end

  # maximize_link — anchor with `data-turbo-stream="true"` so the
  # GET request negotiates a turbo_stream response. The server
  # (MetricsController#chart) renders a stream that updates the
  # shared #chart-modal-* slots and fires the chart_modal_open
  # action — all in one request, no client-side state to manage.
  #
  # Trade-off vs button + JS controller: cmd-click NOW opens
  # /metrics/chart in a new tab as a normal page (format.html
  # fallback). Previously this would just no-op or open a JS-only
  # action. Honest hyperlink semantics restored for free.
  def maximize_link
    a(
      href: @expand_url,
      data: { turbo_stream: "true" },
      title: "Expand chart",
      "aria-label": "Expand #{@label} chart",
      class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 shrink-0"
    ) do
      render Icon::ArrowsPointingOutOutline.new(class: "w-3.5 h-3.5")
    end
  end

  def stat_chip(label, value)
    span(class: "text-[11px] font-voodu-mono text-voodu-muted") do
      plain "#{label} "
      span(class: "text-voodu-text-2") { format_value(value) }
    end
  end

  # capacity_chip — the "of Y · NN%" suffix that pairs the headline
  # current value with the resource's total. Renders just to the
  # right of the headline so the operator reads "21.9 GB / 39 GB ·
  # 56%" as one cohesive measurement. Muted styling keeps it from
  # competing with the headline.
  def capacity_chip
    span(
      class: "font-voodu-mono text-[12px] text-voodu-muted",
      title: @capacity_pct ? "current / total · #{@capacity_pct}% used" : "current / total"
    ) do
      plain "/ #{@capacity_label}"
      if @capacity_pct
        plain " · "
        span(class: "text-voodu-text-2") { "#{@capacity_pct}%" }
      end
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
