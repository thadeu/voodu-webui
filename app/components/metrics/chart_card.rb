# frozen_string_literal: true

# Components::Metrics::ChartCard — header (label + current value +
# min/avg/max strip + maximize button) + a Components::Metrics::Chart
# underneath. 2x2 grid layout on /metrics renders four of these per
# resource and per HTTP scope.
#
# Visual:
#
#   ┌───────────────────────────────────────────────────────────┐
#   │ CPU  25%        min 21.9  avg 30.8  max 39.8  ⛶           │
#   │ ┌───────────────────────────────────────────────────────┐ │
#   │ │ chart …                                               │ │
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
  # chart_type: STRING — "area" (default, the time-series line+fill),
  # "gauge_radial" (semicircle dial), or "gauge_linear" (capacity bar).
  # Gauges need a ceiling (a percent metric, or a capacity_pct); when
  # that's missing the card silently falls back to the area chart so a
  # gauge panel on a limitless metric never renders blank.
  def initialize(label:, color:, unit:, points:, range_ms:, current: nil, expand_url: nil, metric: nil, section: nil, default_visible: true, capacity_label: nil, capacity_pct: nil, chart_type: "area", percent: true, series: nil)
    @label = label
    @color = color
    @unit = unit
    @points = Array(points)
    # series — OPTIONAL multi-series (pilot: Line): one line per pod. When
    # present the card renders a multi Chart + a legend instead of the single
    # headline/stat strip. See Components::Metrics::Chart#series.
    @series = series.is_a?(Array) ? series : nil
    @range_ms = range_ms
    @current = current
    @expand_url = expand_url
    @metric = metric
    @section = section
    @default_visible = default_visible
    @capacity_label = capacity_label
    @capacity_pct = capacity_pct
    @chart_type = chart_type
    # percent — false makes gauges read the raw value in the center instead of
    # the fill "%" (a count has no natural ceiling → "% of peak" confuses).
    @percent = percent
  end

  def view_template
    root_data = {}

    if @metric
      root_data[:metrics_display_target] = "card"
      root_data[:metric_key] = @metric
    end

    root_data[:section] = @section if @section
    root_data[:default_visible] = "false" unless @default_visible

    div(
      class: "relative bg-voodu-surface border border-voodu-border p-3.5 flex flex-col gap-2 min-w-0",
      data: root_data
    ) do
      card_header
      render_body
      stat_footer
      if @metric
        resize_handle("left")
        resize_handle("right")
      end
    end
  end

  private

  # resize_handle — grab strip on the card's LEFT or RIGHT edge. Dragging it
  # changes how many grid columns the card spans (metrics-display#startResize
  # snaps to columns + persists); the left edge just inverts the drag direction.
  # Only on cards with a metric key (the resizable ones); a no-op on mobile
  # (single-column grid). The SVG chart reflows on the width change via the
  # metrics-chart ResizeObserver.
  def resize_handle(edge)
    div(
      data: {action: "pointerdown->metrics-display#startResize", resize_edge: edge},
      aria: {hidden: "true"},
      title: "Drag to resize",
      class: tokens(
        "absolute top-0 bottom-0 w-1.5 cursor-col-resize hover:bg-voodu-accent/30 active:bg-voodu-accent/60 z-10 touch-none",
        (edge == "left") ? "left-0" : "right-0"
      )
    )
  end

  # render_body — the chart_type switch. Gauges fall back to the area
  # chart when there's no usable ceiling (see gauge_pct).
  # multi? — a multi-series (multi-pod) panel drawing one line per series.
  def multi? = !@series.nil? && @series.any?

  def render_body
    if multi?
      return render Components::Metrics::Chart.new(
        points: [], series: @series,
        color: @color, unit: @unit, label: @label,
        # Line (raio) or Area (raio + translucent fill) — same multi machinery.
        range_ms: @range_ms, height: 200, style: chart_style,
        # @metric is the panel_key on a dashboard card — a stable id the chart
        # keys its hidden-line state to so it survives realtime stream refreshes.
        key: @metric
      )
    end

    # Gauges are short; flex-1 lets the body grow to the card height (grid
    # rows stretch to the tallest area chart) so the min/avg/max footer
    # sits pinned at the bottom instead of floating mid-card.
    if gauge?
      div(class: "flex-1 flex flex-col justify-center") do
        if gauge_radial?
          render Components::Metrics::GaugeRadial.new(
            pct: gauge_pct, color: @color, sub_label: gauge_sub_label,
            percent: @percent, value_label: gauge_center_value
          )
        else
          render Components::Metrics::GaugeLinear.new(
            pct: gauge_pct, color: @color,
            value_label: gauge_value_label, capacity_label: @capacity_label,
            percent: @percent, center_value: gauge_center_value
          )
        end
      end
    else
      render Components::Metrics::Chart.new(
        points: @points,
        color: @color,
        unit: @unit,
        label: @label,
        range_ms: @range_ms,
        height: 200,
        style: chart_style,
        # Stable panel id so a single-series Line chart also keys its "Show
        # dots" pref (options menu). Harmless on area/bars (no menu, no dots).
        key: @metric
      )
    end
  end

  # chart_style — Bar / Line / Area for the non-gauge branch.
  def chart_style
    case @chart_type.to_s
    when "bars" then :bars
    when "line" then :line
    else :area
    end
  end

  def gauge? = gauge_radial? || gauge_linear?
  def gauge_radial? = @chart_type.to_s == "gauge_radial" && !gauge_pct.nil?
  def gauge_linear? = @chart_type.to_s == "gauge_linear" && !gauge_pct.nil?

  # gauge_pct — the 0..100 fill. Capacity metrics (memory/disk) use the
  # computed capacity_pct; percent metrics (CPU%) use the value itself.
  # nil → no ceiling → ChartCard renders the area chart instead.
  def gauge_pct
    return @capacity_pct unless @capacity_pct.nil?
    return @current || stats[:current] if percent_unit?

    nil
  end

  # gauge_sub_label — radial center sub-line: "13.2 / 42 GB" for a
  # capacity metric, nil for a percent metric (the % already is it).
  def gauge_sub_label
    return nil unless @capacity_label

    v = @current || stats[:current]
    return @capacity_label if v.nil?

    "#{MetricFormat.number(v)} / #{@capacity_label}"
  end

  # gauge_value_label — linear "used" figure ("13.2 GB"); nil for a
  # percent metric.
  def gauge_value_label
    return nil if percent_unit? || @capacity_label.nil?

    v = @current || stats[:current]
    v.nil? ? nil : "#{MetricFormat.number(v)} #{@unit}".strip
  end

  # gauge_center_value — the raw current value the radial shows in its center
  # when percent: false (a count reads clearer than "% of peak").
  def gauge_center_value
    v = @current || stats[:current]
    v.nil? ? nil : "#{MetricFormat.number(v)} #{@unit}".strip
  end

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

    # Header carries ONLY the identity + headline now: label + [http]
    # badge + current value + capacity, with the maximize pinned
    # top-right (shrink-0, outside the wrapping flow so it never orphans
    # at narrow widths). The min/avg/max strip moved to stat_footer
    # under the chart — mirrors the expand modal's layout, keeps the
    # header clean and uncluttered on a 4-up grid.
    # Header is single-line (no flex-wrap): a narrow card in a 4-up grid must
    # NOT wrap the label/value/capacity onto a second line — that grows the card
    # and pushes the whole grid row taller, breaking footer alignment across the
    # row. Instead the label + capacity truncate (ellipsis) under pressure while
    # the headline value (shrink-0) stays whole.
    div(class: "flex items-start justify-between gap-2") do
      div(class: "flex items-baseline gap-x-2.5 min-w-0 overflow-hidden") do
        span(
          class: "text-[11.5px] font-semibold uppercase tracking-[0.05em] min-w-0 truncate",
          style: "color: #{@color};"
        ) { @label }

        # [http] inline badge — replaces the old HTTP section divider.
        # Same visual signal ("this metric comes from ingress logs") but
        # without splitting the grid into two boxes.
        if @section == "http"
          span(
            class: "text-[9.5px] font-voodu-mono text-voodu-muted-2 uppercase tracking-[0.06em] " \
                   "border border-voodu-border px-1 py-px translate-y-[-1px] shrink-0",
            title: "HTTP metric (ingress)"
          ) { "http" }
        end

        # Render number + unit. For percent metrics the unit is part
        # of the formatted string (so we can show "<0.01%" without
        # the magnitude tier rendering "<0.01" with a separate "%"
        # span looking like "<0.01 %"). For everything else the
        # number stays plain and the unit hangs in its own muted
        # span.
        # Multi-series has no single headline value — show the pod count.
        if multi?
          span(class: "font-voodu-mono text-[12px] text-voodu-muted shrink-0 whitespace-nowrap") { "#{@series.size} pods" }
        end

        # Gauges render the value + capacity inside the dial/bar, so the
        # header drops the big number to avoid showing it twice.
        unless gauge? || multi?
          span(class: "font-voodu-mono text-[22px] font-semibold text-voodu-text shrink-0 whitespace-nowrap") do
            if percent_unit?
              plain format_current(@current || s[:current])
            else
              plain format_current(@current || s[:current])
              span(class: "text-voodu-muted text-[12px] font-normal ml-0.5") { @unit }
            end
          end

          capacity_chip if @capacity_label
        end
      end

      # Top-right actions: the per-panel options menu (⋮, Line only for now)
      # sits LEFT of the maximize (⛶), which stays pinned in the corner.
      div(class: "flex items-center gap-0.5 shrink-0") do
        options_menu if options_menu?
        maximize_link if @expand_url
      end
    end
  end

  # options_menu? — which panels get the ⋮ options menu. Its sole option today
  # ("Show dots") only makes sense where dots exist: Line (single + multi always
  # draw dots) and multi Area (one dotted line per pod). Single Area has no dots,
  # so it gets no menu.
  def options_menu?
    return true if @chart_type.to_s == "line"

    multi? && @chart_type.to_s == "area"
  end

  # options_menu — the triple-dot popover. The trigger lives in the header; the
  # menu (portaled out on open by the popover controller to escape clipping)
  # carries its own panel-options controller keyed by the panel id, so its
  # toggle persists + broadcasts to the matching chart. Content must be self-
  # contained (no data-action bound to an ancestor that won't survive portaling).
  def options_menu
    div(class: "relative", data: {controller: "popover"}) do
      button(
        type: "button",
        data: {popover_target: "trigger", action: "popover#toggle"},
        class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2",
        aria: {label: "Panel options", haspopup: "true"}, title: "Panel options"
      ) { render Icon::EllipsisVerticalOutline.new(class: "w-4 h-4") }

      div(
        hidden: true,
        data: {popover_target: "menu", controller: "panel-options", panel_options_key_value: @metric},
        class: "min-w-[220px] bg-voodu-surface-2 border border-voodu-border shadow-xl overflow-hidden"
      ) do
        # Header — names the panel, like a dropdown's section header.
        div(class: "px-3 py-2 border-b border-voodu-border text-[10.5px] font-semibold uppercase tracking-[0.06em] text-voodu-muted-2 truncate") { @label }

        # Option row — label + kbd hint (left), macOS-style switch (right).
        label(class: "flex items-center justify-between gap-3 px-3 py-2.5 text-[12px] text-voodu-text-2 hover:bg-voodu-surface cursor-pointer select-none") do
          span(class: "flex items-center gap-2 min-w-0") do
            plain "Show dots"
            option_kbd("B")
          end
          option_switch("dots")
        end
      end
    end
  end

  # option_switch — a hidden checkbox (the a11y control + source of truth) styled
  # as a macOS toggle via Tailwind `peer`: the track + knob react to peer-checked.
  # The panel-options controller reads/writes the checkbox.
  def option_switch(name)
    span(class: "relative inline-flex items-center shrink-0 w-[34px] h-[20px]") do
      input(
        type: "checkbox", checked: true,
        data: {panel_options_target: name, action: "change->panel-options#toggleDots"},
        class: "peer sr-only"
      )
      span(class: "absolute inset-0 rounded-full bg-voodu-border transition-colors peer-checked:bg-voodu-accent")
      span(class: "absolute left-[3px] top-[3px] w-[14px] h-[14px] rounded-full bg-white shadow transition-transform peer-checked:translate-x-[14px]")
    end
  end

  # option_kbd — the shortcut hint beside an option: pressing the key toggles it
  # while the popover is open (see panel_options_controller).
  def option_kbd(key)
    span(class: "inline-flex items-center justify-center min-w-[16px] h-4 px-1 rounded border border-voodu-border bg-voodu-surface text-[10px] font-voodu-mono text-voodu-muted-2 leading-none") { key }
  end

  # stat_footer — min/avg/max strip BELOW the chart, mirroring the
  # expand modal's footer (Views::Metrics::ChartModalBody#stat_strip).
  # Frees the header of the stats clutter so it stays clean even on a
  # 4-up grid. Skipped when there's no data (the chart shows its own
  # empty state).
  def stat_footer
    # Multi-series draws its own interactive legend inside the Chart (so the
    # legend buttons sit in the metrics-chart controller scope + can toggle the
    # lines). Nothing extra to render here.
    return if multi?
    return if @points.empty?

    s = stats

    # Single line, no wrap: a narrow card must keep min/avg/max on ONE row so
    # the card height stays constant across the grid (a wrapped footer grows the
    # card and misaligns the whole row). Block + nowrap + text-ellipsis clips
    # with a "…" instead of breaking to a second line.
    div(class: "min-w-0 overflow-hidden text-ellipsis whitespace-nowrap px-0.5") do
      stat_chip("min", s[:min])
      stat_chip("avg", s[:avg])
      stat_chip("max", s[:max])
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
      data: {turbo_stream: "true"},
      title: "Expand chart",
      "aria-label": "Expand #{@label} chart",
      class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 shrink-0"
    ) do
      render Icon::ArrowsPointingOutOutline.new(class: "w-3.5 h-3.5")
    end
  end

  # stat_chip — footer min/avg/max chip. Matches the expand modal's
  # stat_strip vocabulary (muted label + emphasized value) so the
  # inline card and the modal read the same.
  # stat_chip — inline (NOT a flex item) so the parent's text-ellipsis can clip
  # the row as one continuous line. mr-4 spaces the chips (last:mr-0 drops the
  # trailing gap); inline-block would make each chip atomic and break the
  # single-line ellipsis, so they stay plain inline spans.
  def stat_chip(label, value)
    span(class: "text-[11px] font-voodu-mono text-voodu-muted mr-4 last:mr-0") do
      plain "#{label} "
      span(class: "text-voodu-text font-semibold") { format_value(value) }
    end
  end

  # capacity_chip — the "of Y · NN%" suffix that pairs the headline
  # current value with the resource's total. Renders just to the
  # right of the headline so the operator reads "21.9 GB / 39 GB ·
  # 56%" as one cohesive measurement. Muted styling keeps it from
  # competing with the headline.
  def capacity_chip
    span(
      class: "font-voodu-mono text-[12px] text-voodu-muted min-w-0 truncate",
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
    return {min: nil, max: nil, avg: nil, current: nil} if @points.empty?

    values = @points.map { |p| p[:value].to_f }
    sum = values.sum
    current = values.last

    {
      min: values.min,
      max: values.max,
      avg: sum / values.size,
      current: current
    }
  end
end
