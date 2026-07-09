# frozen_string_literal: true

# Components::Metrics::Chart — the BIG time-series chart on /metrics.
# Distinct from Components::UI::Sparkline (which is the tiny inline
# chart on StatCards) because the metrics page has room — and the
# need — for full axes, gridlines, restart annotations, and a
# proper hover tooltip.
#
# Ported 1:1 from design-webui-inspiration/pages-metrics.jsx
# (MetricChart, lines 177-333). The Catmull-Rom→bezier smoothing
# is identical to Sparkline's path_for; we don't dedup to keep
# each chart's coordinate space (with axis padding) local — they
# diverge enough that extraction would be premature.
#
# Markup pattern:
#
#   <div data-controller="metrics-chart"
#        data-metrics-chart-points-value="[{ts, value, formatted}]"
#        data-metrics-chart-color-value="#34d399"
#        data-metrics-chart-unit-value="%"
#        data-metrics-chart-label-value="CPU">
#     <svg ...>            <!-- axes + path + (JS-injected hover overlay) -->
#       ... rendered server-side ...
#     </svg>
#     <!-- floating tooltip rendered into <body> by Stimulus -->
#   </div>
#
# The SVG itself is server-rendered (axes, gridlines, path) so the
# initial paint shows a complete chart even before JS hydrates.
# The Stimulus controller only adds the crosshair + tooltip on
# mouseover; without JS the static chart still reads.
class Components::Metrics::Chart < Components::Base
  # Padding for the full chart (with visible axes). Compact mode
  # (axes hidden) collapses these to tiny gutters.
  PAD_LEFT_FULL = 44   # room for y-axis labels
  PAD_RIGHT_FULL = 12
  PAD_TOP_FULL = 14
  PAD_BOTTOM_FULL = 22   # room for x-axis labels

  PAD_LEFT_COMPACT = 4
  PAD_RIGHT_COMPACT = 4
  PAD_TOP_COMPACT = 4
  PAD_BOTTOM_COMPACT = 4

  Y_TICKS = 5
  X_TICKS = 5

  # axes: true → big chart with full Y/X labels + gridlines
  #       false → compact (sparkline-like): same curve + same
  #       hover crosshair + tooltip, no visible axes. Used by
  #       Overview StatCards and Pod show StatCards so all three
  #       chart surfaces (Overview, Pod show, /metrics) share
  #       the same SVG/JS rendering engine.
  # style — how the series is drawn, all sharing the same axes / timeline /
  # hover / restart annotations / brush-to-zoom:
  #   :area (default) — smoothed curve + gradient fill
  #   :bars           — one filled column per bucket (discrete counts)
  #   :line           — smoothed curve + a dot on each point, NO fill
  STYLES = %i[area bars line].freeze

  # series — OPTIONAL multi-series data (pilot: Line only). An array of
  # {label:, color:, points: [{ts,value,formatted}]}. When present the chart
  # draws ONE line (+ dots) per series on shared axes (y = max across all
  # series, x = union of their time range). `points`/`color` are ignored.
  def initialize(points:, color:, unit:, label:, range_ms:, height: 200, width: 600, axes: true, style: :area, zoom_url: nil, series: nil, key: nil, legend: true)
    # key — a STABLE per-chart id (the panel_key on a dashboard). Emitted so the
    # multi-series controller can persist which lines the operator hid ACROSS a
    # realtime Turbo Stream refresh (which replaces the chart DOM + reconnects).
    @key = key
    # legend — draw the multi-series legend under the chart. Off for a Number
    # tile's multi timeline, where the colored per-pod headlines ARE the legend.
    @legend = legend
    @series = series.is_a?(Array) ? series : nil
    @points = Array(points)
    @color = color
    @unit = unit
    @label = label
    @range_ms = range_ms.to_i
    @height = height
    @width = width
    @axes = axes
    @style = STYLES.include?(style&.to_sym) ? style.to_sym : :area
    # zoom_url — the /metrics/chart endpoint URL for THIS chart (with its
    # metric/scope/server params). Present only when the chart lives inside
    # the expand modal: brush-to-zoom then re-fetches the modal body at the
    # brushed window (range=custom&from&until) instead of navigating the whole
    # page — which would tear the modal down. Absent on the grid → brush does
    # a full-page Turbo.visit, which is the right behavior there.
    @zoom_url = zoom_url
  end

  def bars? = @style == :bars

  def line? = @style == :line

  def area? = @style == :area

  def pad_left
    @axes ? PAD_LEFT_FULL : PAD_LEFT_COMPACT
  end

  def pad_right
    @axes ? PAD_RIGHT_FULL : PAD_RIGHT_COMPACT
  end

  def pad_top
    @axes ? PAD_TOP_FULL : PAD_TOP_COMPACT
  end

  def pad_bottom
    @axes ? PAD_BOTTOM_FULL : PAD_BOTTOM_COMPACT
  end

  def multi? = !@series.nil? && @series.any? { |s| Array(s[:points]).any? }

  def view_template
    return render_multi if multi?

    # Truly empty → honest "no data" placeholder (cold boot, no
    # samples on disk or in warehouse for this range yet).
    if @points.empty?
      return div(
        class: "flex items-center justify-center text-voodu-muted text-[12px]",
        style: "height: #{@height}px;"
      ) { "no data" }
    end

    # Single point edge case — happens when the range/interval is
    # narrow enough that only one bucket has samples (warehouse
    # warming up, brand-new server, or very short range). The
    # operator already sees a meaningful value in the StatCard
    # headline pulled from that same point; the chart should render
    # a flat line at that level rather than say "no data" (which
    # contradicts the headline + min/avg/max next to it). We
    # duplicate the point so the curve has 2 vertices to draw.
    if @points.size == 1
      only = @points.first
      @points = [only, only]
    end

    pts = projected_points
    y_max = y_axis_max
    x_min, x_max = time_bounds

    div(
      class: "relative w-full",
      data: {
        controller: "metrics-chart",
        metrics_chart_points_value: points_for_js.to_json,
        metrics_chart_segments_value: normalized_segments.to_json,
        metrics_chart_color_value: @color,
        metrics_chart_unit_value: @unit,
        metrics_chart_label_value: @label,
        metrics_chart_width_value: @width,
        metrics_chart_height_value: @height,
        metrics_chart_pad_left_value: pad_left,
        metrics_chart_pad_right_value: pad_right,
        metrics_chart_pad_top_value: pad_top,
        metrics_chart_pad_bottom_value: pad_bottom,
        metrics_chart_baseline_y_value: baseline_y,
        # Interpolation for the path REBUILT on resize: "linear" (Line style,
        # straight point-to-point) vs "step" (area — honest step-after). Must
        # match the server-rendered path above or a resize would flip the look.
        metrics_chart_interp_value: (line? ? "linear" : "step"),
        # responsive: client measures actual container width on
        # connect + on resize, then rewrites viewBox to
        # `0 0 <measuredW> <height>` and reprojects path + axis
        # ticks using the normalized segments above. Result: chart
        # fills container fully WITHOUT squishing text (every SVG
        # unit == 1 CSS pixel after takeover). Server-rendered
        # snapshot below uses @width/@height as a no-JS fallback.
        metrics_chart_responsive_value: true,
        # Timezone the JS tooltip should format timestamps in.
        # Matches the same WebTime.zone_name driving the server-
        # rendered X-axis ticks, so a hover label and the axis
        # tick directly below agree on TZ.
        metrics_chart_timezone_value: WebTime.zone_name,
        # Stable panel id so the "Show dots" pref (options menu) keys correctly.
        **(@key.present? ? {metrics_chart_key_value: @key} : {}),
        # Only emitted in the expand modal (see @zoom_url). Its mere
        # PRESENCE is what the controller keys on (hasZoomUrlValue) to
        # pick the in-modal re-fetch over a full-page navigation, so it
        # must stay absent — not empty — on the grid.
        **(@zoom_url.present? ? {metrics_chart_zoom_url_value: @zoom_url} : {})
      }
    ) do
      # ── Responsive strategy ────────────────────────────────────
      #
      # The server emits a COMPLETE chart at viewBox=@width × @height
      # (default 600×200) so no-JS users see a coherent snapshot.
      # `preserveAspectRatio="xMidYMid meet"` (default) keeps the
      # aspect intact — text stays round, dots stay circular —
      # accepting horizontal whitespace on wider containers.
      #
      # Then metrics_chart_controller.js takes over: it measures
      # the container's CSS width, sets viewBox to `0 0 W <height>`,
      # and rewrites every x-coordinate (path, axis tick labels,
      # spanning lines, clip + overlay rects) so 1 viewBox unit ==
      # 1 CSS pixel post-takeover. That keeps text at its design
      # size (10pt SVG = 10px on screen) AND fills the full width.
      #
      # Elements that need x-repositioning on resize are tagged
      # with Stimulus targets below:
      #   line / area              — path rebuilt from segmentsValue
      #   clipRect / overlayRect   — width updated
      #   hLine (multi)            — x2 updated to W - padRight
      #   xTick (multi)            — x updated to padLeft + t * innerW
      svg(
        width: "100%", height: @height,
        viewBox: "0 0 #{@width} #{@height}",
        class: "block overflow-visible",
        style: "touch-action: pan-y;",
        data: {metrics_chart_target: "svg"}
      ) do |s|
        s.defs do
          s.linearGradient(id: gradient_id, x1: 0, y1: 0, x2: 0, y2: 1) do
            s.stop(offset: "0%", "stop-color": @color, "stop-opacity": "0.30")
            s.stop(offset: "100%", "stop-color": @color, "stop-opacity": "0")
          end

          # Bars carry a richer fade (bright top → soft bottom) so a single
          # column still reads as filled, not as a faint sliver.
          if bars?
            s.linearGradient(id: bars_gradient_id, x1: 0, y1: 0, x2: 0, y2: 1) do
              s.stop(offset: "0%", "stop-color": @color, "stop-opacity": "0.85")
              s.stop(offset: "100%", "stop-color": @color, "stop-opacity": "0.22")
            end
          end

          # clipPath bounds the curve + area fill to the chart
          # drawing area. Catmull-Rom bezier interpolation can
          # overshoot the data envelope when adjacent points
          # zig-zag (peak → 0 → peak makes the curve dip BELOW
          # the y=0 baseline, which then bleeds the area fill
          # into the x-axis label region). Clipping is the
          # standard fix; cheaper than swapping to a monotone
          # spline + keeps the smooth aesthetic.
          s.clipPath(id: clip_id) do
            s.rect(
              x: pad_left, y: pad_top,
              width: @width - pad_left - pad_right,
              height: @height - pad_top - pad_bottom,
              data: {metrics_chart_target: "clipRect"}
            )
          end
        end

        # Axes are visible on the big chart (Metrics page). Hidden
        # in compact mode so the StatCards on Overview / Pod show
        # render as bare sparklines — same engine, no clutter.
        if @axes
          render_y_axis(s, y_max)
          render_x_axis(s, x_min, x_max)
        end

        # Style switch — all three share axes/hover/brush; only the mark differs.
        #   bars → one filled column per bucket
        #   line → smoothed stroke + a dot per point, NO fill
        #   area → smoothed stroke + gradient fill
        if bars?
          render_bars(s, pts, clip_id)
        else
          # Stroke (and, for area, the fill) go through the clip so a
          # Catmull-Rom overshoot below the baseline is invisibly cropped.
          s.g("clip-path": "url(##{clip_id})") do
            if area?
              s.path(
                d: area_path_for(pts), fill: "url(##{gradient_id})",
                data: {metrics_chart_target: "area"}
              )
            end

            s.path(
              d: path_for(pts), fill: "none", stroke: @color, "stroke-width": "1.5",
              "stroke-linecap": "round", "stroke-linejoin": "round",
              data: {metrics_chart_target: "line"}
            )
          end

          # Line style: a dot on each data point (OUTSIDE the clip so an edge
          # dot isn't half-cropped). Reprojected on resize via data-x-norm.
          render_dots(s, pts) if line?
        end

        # Frame baseline — solid line at the bottom of the chart
        # area, distinct from the dashed y=0 gridline since the
        # chart's bottom often clips into the x-axis label band.
        # Compact mode skips it (no axis area to demarcate).
        if @axes
          s.line(
            x1: pad_left, x2: @width - pad_right,
            y1: baseline_y, y2: baseline_y,
            stroke: "var(--voodu-border)",
            data: {metrics_chart_target: "hLine"}
          )
        end

        # Hover overlay rect — full chart area minus padding.
        # Single rect (vs one-per-point) because the JS finds the
        # nearest point via x-distance, matching the inspiration's
        # `onMove` handler. Cursor crosshair signals interactivity.
        s.rect(
          x: pad_left, y: pad_top,
          width: @width - pad_left - pad_right,
          height: @height - pad_top - pad_bottom,
          fill: "transparent", "pointer-events": "all",
          style: "cursor: crosshair;",
          data: {
            metrics_chart_target: "overlay",
            # Brush-to-zoom (drag a time range → reload at range=custom) works
            # for every style — a time sub-range maps the same whether the mark
            # is an area, a line, or bars.
            action: "mousemove->metrics-chart#move mouseleave->metrics-chart#leave mousedown->metrics-chart#brushStart"
          }
        )
      end
    end
  end

  private

  # ── Multi-series (pilot: Line) ─────────────────────────────────────────────
  #
  # One line + dots per series on SHARED axes (y = nice_ceil of the max value
  # across all series, x = union time range). Reuses the single-series axes
  # (render_y_axis/render_x_axis), clip, linear stroke (linear_segment_path),
  # and the responsive machinery — dots carry x_norm like the single path, and
  # each line carries a series_index so the resize rebuild targets it.

  def render_multi
    bounds = multi_bounds
    inner_w = (@width - pad_left - pad_right).to_f

    div(
      class: "relative w-full",
      data: {
        controller: "metrics-chart",
        metrics_chart_series_value: multi_series_for_js(bounds).to_json,
        metrics_chart_multi_value: true,
        metrics_chart_color_value: @color,
        metrics_chart_unit_value: @unit,
        metrics_chart_label_value: @label,
        metrics_chart_width_value: @width,
        metrics_chart_height_value: @height,
        metrics_chart_pad_left_value: pad_left,
        metrics_chart_pad_right_value: pad_right,
        metrics_chart_pad_top_value: pad_top,
        metrics_chart_pad_bottom_value: pad_bottom,
        metrics_chart_baseline_y_value: baseline_y,
        metrics_chart_interp_value: "linear",
        metrics_chart_responsive_value: true,
        metrics_chart_timezone_value: WebTime.zone_name,
        # Stable id so hidden-line selections survive a realtime stream refresh.
        **(@key.present? ? {metrics_chart_key_value: @key} : {})
      }
    ) do
      svg(
        width: "100%", height: @height, viewBox: "0 0 #{@width} #{@height}",
        class: "block overflow-visible", style: "touch-action: pan-y;",
        data: {metrics_chart_target: "svg"}
      ) do |s|
        s.defs do
          s.clipPath(id: clip_id) do
            s.rect(
              x: pad_left, y: pad_top,
              width: @width - pad_left - pad_right, height: @height - pad_top - pad_bottom,
              data: {metrics_chart_target: "clipRect"}
            )
          end
        end

        if @axes
          render_y_axis(s, bounds[:y_max])
          render_x_axis(s, bounds[:x_min], bounds[:x_max])
        end

        @series.each_with_index do |ser, i|
          pts = project_series(Array(ser[:points]), bounds)
          next if pts.empty?

          color = ser[:color] || @color

          s.g("clip-path": "url(##{clip_id})") do
            # Area multi = the same raio line + a translucent fill down to the
            # baseline. Low opacity so up to 5 overlapping fills stay readable.
            if area?
              s.path(
                d: linear_area_path(pts), fill: color, "fill-opacity": "0.14", stroke: "none",
                data: {metrics_chart_target: "area", series_index: i}
              )
            end

            s.path(
              d: linear_segment_path(pts), fill: "none", stroke: color, "stroke-width": "1.5",
              "stroke-linecap": "round", "stroke-linejoin": "round",
              data: {metrics_chart_target: "line", series_index: i}
            )
          end

          pts.each do |x, y|
            x_norm = (inner_w.positive? ? (x - pad_left) / inner_w : 0).round(5)

            s.circle(cx: x.round(2), cy: y.round(2), r: "2.5", fill: color,
              data: {metrics_chart_target: "dot", x_norm: x_norm, series_index: i})
          end
        end

        if @axes
          s.line(
            x1: pad_left, x2: @width - pad_right, y1: baseline_y, y2: baseline_y,
            stroke: "var(--voodu-border)", data: {metrics_chart_target: "hLine"}
          )
        end

        s.rect(
          x: pad_left, y: pad_top,
          width: @width - pad_left - pad_right, height: @height - pad_top - pad_bottom,
          fill: "transparent", "pointer-events": "all", style: "cursor: crosshair;",
          data: {
            metrics_chart_target: "overlay",
            action: "mousemove->metrics-chart#move mouseleave->metrics-chart#leave mousedown->metrics-chart#brushStart"
          }
        )
      end

      render_multi_legend if @legend
    end
  end

  # render_multi_legend — the interactive key under a multi-series chart. Each
  # entry is a BUTTON living INSIDE the metrics-chart controller root (so it can
  # reach the lines/dots by series_index):
  #   HOVER  → spotlight this series (the controller dims the others)
  #   CLICK  → toggle this line's visibility (hide/show)
  # Wraps on narrow cards; the swatch + label read the same as the old footer
  # legend, now with pointer affordance + a11y aria-pressed.
  def render_multi_legend
    div(class: "flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] font-voodu-mono mt-2 px-0.5") do
      @series.each_with_index do |ser, i|
        color = ser[:color] || @color
        cur = ser[:current]

        button(
          type: "button",
          class: "inline-flex items-center gap-1.5 min-w-0 cursor-pointer select-none transition-opacity",
          aria: {pressed: "true", label: "Toggle #{ser[:label]} line"},
          title: "Click to hide/show · hover to highlight",
          data: {
            metrics_chart_target: "legendItem",
            series_index: i,
            action: "mouseenter->metrics-chart#highlightSeries " \
                    "mouseleave->metrics-chart#unhighlightSeries " \
                    "click->metrics-chart#toggleSeries"
          }
        ) do
          span(class: "inline-block w-2.5 h-2.5 rounded-sm shrink-0", style: "background: #{color};")
          span(class: "text-voodu-text-2 truncate", data: {legend_label: true}) { ser[:label].to_s }
          span(class: "text-voodu-muted shrink-0") { format_series_current(cur) } unless cur.nil?
        end
      end
    end
  end

  # format_series_current — the legend's latest value per series. Mirrors
  # ChartCard#format_current (percent bakes the % in; others go number-only).
  def format_series_current(v)
    return "—" if v.nil?

    (@unit == "%") ? MetricFormat.percent(v) : MetricFormat.number(v)
  end

  # multi_bounds — shared axes: y ceiling = nice_ceil of the max value anywhere;
  # x = union time range. Every series projects onto these.
  def multi_bounds
    values = @series.flat_map { |s| Array(s[:points]).map { |p| p[:value].to_f } }
    times = @series.flat_map { |s| Array(s[:points]).map { |p| parse_ts_ms(p[:ts]) } }

    {y_max: nice_ceil(values.max || 0), x_min: times.min || 0, x_max: times.max || 0}
  end

  # project_series — one series' points → [[x,y]] on the shared bounds.
  def project_series(points, bounds)
    inner_w = (@width - pad_left - pad_right).to_f
    inner_h = (@height - pad_top - pad_bottom).to_f
    x_span = [(bounds[:x_max] - bounds[:x_min]).to_f, 1.0].max
    y_span = [bounds[:y_max].to_f, 0.0001].max

    points.map do |p|
      t = parse_ts_ms(p[:ts])
      x = pad_left + ((t - bounds[:x_min]) / x_span) * inner_w
      y = pad_top + (1 - (p[:value].to_f / y_span)) * inner_h
      [x, y]
    end
  end

  # multi_series_for_js — per series: color, label, and points with x_norm
  # (0..1 on the shared x) + y (viewBox units) so the controller rebuilds each
  # line on resize and drives the shared hover tooltip.
  def multi_series_for_js(bounds)
    inner_w = (@width - pad_left - pad_right).to_f

    @series.map do |s|
      pts = Array(s[:points])
      proj = project_series(pts, bounds)

      {
        label: s[:label].to_s,
        color: s[:color] || @color,
        points: pts.each_with_index.map do |p, i|
          x, y = proj[i]

          {ts: p[:ts], value: p[:value], formatted: p[:formatted],
           x_norm: (inner_w.positive? ? (x - pad_left) / inner_w : 0).round(5), y: y.round(2)}
        end
      }
    end
  end

  # points_for_js — pre-projected points the Stimulus controller
  # consumes for hover nearest-x lookup. Keeps the coordinate math
  # in one place (server-side) and lets the JS stay tiny: find
  # nearest by x, position tooltip + crosshair using the same px
  # the SVG already painted.
  #
  # x_norm is the point's x position normalized to [0, 1] within
  # the inner chart area (between padLeft and width-padRight). On
  # resize the controller recomputes the absolute x via
  # `padLeft + x_norm * innerW` so hover lookup follows the chart
  # as its viewBox stretches to match the container.
  def points_for_js
    pts = projected_points
    inner_w = (@width - pad_left - pad_right).to_f

    return [] if inner_w <= 0

    @points.each_with_index.map do |p, i|
      abs_x = pts[i][0]
      {
        ts: p[:ts],
        value: p[:value],
        formatted: p[:formatted],
        x: abs_x.round(2),
        x_norm: ((abs_x - pad_left) / inner_w).round(5),
        y: pts[i][1].round(2)
      }
    end
  end

  # normalized_segments — same gap-detected step-after segments
  # used by the server-side path, but with each point's x stored
  # as a 0-1 ratio of the inner chart area. The Stimulus
  # controller rebuilds the path d-strings on resize by mapping
  # `x_norm → padLeft + x_norm * (W - padLeft - padRight)` against
  # the measured container width.
  #
  # Returning normalized segments (instead of raw points) means
  # the chart honours its gap policy across resize too: a 3-hour
  # outage stays as two disconnected servers of data in the wide
  # post-resize chart, never auto-bridged.
  def normalized_segments
    pts = projected_points
    inner_w = (@width - pad_left - pad_right).to_f

    return [] if pts.empty? || inner_w <= 0

    segments_of(pts).map do |seg|
      seg.map { |x, y| [((x - pad_left) / inner_w).round(5), y.round(2)] }
    end
  end

  def projected_points
    y_max = y_axis_max
    x_min, x_max = time_bounds

    inner_w = (@width - pad_left - pad_right).to_f
    inner_h = (@height - pad_top - pad_bottom).to_f
    x_span = [(x_max - x_min).to_f, 1.0].max
    y_span = [y_max.to_f, 0.0001].max

    @points.map do |p|
      t = parse_ts_ms(p[:ts])
      x = pad_left + ((t - x_min) / x_span) * inner_w
      y = pad_top + (1 - (p[:value].to_f / y_span)) * inner_h
      [x, y]
    end
  end

  def raw_max
    @points.map { |p| p[:value].to_f }.max
  end

  # y_axis_max — single source of truth for the chart's Y ceiling.
  # Both the gridline renderer (render_y_axis) and the point
  # projection (projected_points) must agree, or the dots float
  # above the top gridline. Centralised here.
  #
  # No multiplicative padding — `nice_ceil` already rounds UP to
  # the next clean number (5, 7.5, 10, 25, 50, 75, 100, …), which
  # naturally puts a peak below the chart's top edge in every
  # case EXCEPT when the peak sits exactly at a bucket boundary
  # (e.g. CPU pegged at 100%). At that boundary we accept the
  # peak kissing the top — it's honest ("you're at the cap") and
  # adding padding would jump the axis to 2× the bucket size
  # (100 × 1.05 = 105 → ceil → 200, the bug the operator caught).
  def y_axis_max
    nice_ceil(raw_max)
  end

  def time_bounds
    parsed = @points.map { |p| parse_ts_ms(p[:ts]) }
    [parsed.min, parsed.max]
  end

  def parse_ts_ms(iso)
    return 0 if iso.blank?

    Time.iso8601(iso.to_s).to_f * 1000
  rescue ArgumentError
    0
  end

  def baseline_y
    @height - pad_bottom
  end

  # render_y_axis — 5 horizontal gridlines + numeric labels on the
  # left. The first (y=0) gridline is invisible (the frame baseline
  # already draws there). Labels use the chart's "max value" rounded
  # to a nice number so axis values read like 0, 25, 50, 75, 100
  # instead of 0, 23.7, 47.4, 71.1, 94.8.
  def render_y_axis(svg, y_max)
    (0..(Y_TICKS - 1)).each do |i|
      t = i.to_f / (Y_TICKS - 1)
      v = t * y_max
      y = pad_top + (1 - t) * (@height - pad_top - pad_bottom)

      svg.line(
        x1: pad_left, x2: @width - pad_right,
        y1: y, y2: y,
        stroke: "var(--voodu-border)",
        "stroke-opacity": i.zero? ? "0" : "0.5",
        data: {metrics_chart_target: "hLine"}
      )

      # Y-axis label x stays at pad_left - 6 across resize (the left gutter
      # doesn't change with width). The tick RATIO (t) rides on the element so a
      # multi-series chart can relabel it when a legend toggle rescales the Y
      # ceiling (label value = t × y_max) — see metrics-chart#applyYScale.
      svg.text(
        x: pad_left - 6, y: y + 3.5,
        "text-anchor": "end",
        "font-size": "10",
        fill: "var(--voodu-muted-2)",
        "font-family": "var(--voodu-font-mono, ui-monospace, monospace)",
        data: {metrics_chart_target: "yTick", y_tick_ratio: t}
      ) { format_axis_number(v) }
    end
  end

  # render_x_axis — 5 timestamps along the bottom. Format adapts
  # to the range (HH:MM:SS for ≤1h, HH:MM for ≤24h, MM/DD beyond).
  # Same logic as fmtAxisTime in pages-metrics.jsx so the labels
  # match the inspiration. Timestamps are converted into the
  # operator's preferred timezone (Settings → Display preferences)
  # via WebTime so chart x-axis ticks read in local time, not UTC.
  def render_x_axis(svg, x_min, x_max)
    span = x_max - x_min

    (0..(X_TICKS - 1)).each do |i|
      t = i.to_f / (X_TICKS - 1)
      ts_ms = x_min + t * span
      ts = Time.at(ts_ms / 1000.0)

      # X-axis labels: x is recomputed on resize as
      # `pad_left + (t * inner_w)`. Stash t on the element so JS
      # can rescale without re-doing the tick loop.
      svg.text(
        x: pad_left + t * (@width - pad_left - pad_right),
        y: @height - 5,
        "text-anchor": "middle",
        "font-size": "10",
        fill: "var(--voodu-muted-2)",
        "font-family": "var(--voodu-font-mono, ui-monospace, monospace)",
        data: {
          metrics_chart_target: "xTick",
          x_tick_ratio: t.round(4)
        }
      ) { format_axis_time(ts) }
    end
  end

  # format_axis_time — pick format that fits the chart's range and
  # render in the operator's timezone:
  #   ≤ 1h    → HH:MM:SS
  #   ≤ 24h   → HH:MM
  #   beyond  → MM/DD
  def format_axis_time(ts)
    pattern =
      if @range_ms <= 60 * 60 * 1000 then "%H:%M:%S"
      elsif @range_ms <= 24 * 60 * 60 * 1000 then "%H:%M"
      else "%m/%d"
      end

    WebTime.strftime(ts, pattern) || ""
  end

  # format_axis_number — Y-axis label compaction. "Nk" for >=1000
  # keeps labels short in the 38-pixel left gutter; below 1000 we
  # defer to MetricFormat.number so sub-1 values keep enough
  # precision to read as more than "0.0" (otherwise a chart with
  # peaks at 0.05 had every gridline labelled "0.0", masking the
  # actual scale).
  def format_axis_number(v)
    abs = v.abs
    return "#{(v / 1000.0).round(1)}k" if abs >= 1000

    MetricFormat.number(v)
  end

  # nice_ceil — rounds a max value up to a "nice" axis ceiling
  # (1, 2, 2.5, 4, 5, 7.5, 10 × 10^n). Without this the Y-axis
  # labels would be ugly raw numbers like 23.7, 47.4, 71.1; with
  # it we get 25, 40, 50, 75, 100.
  #
  # Buckets, with rationale per stop:
  #   1   — small values (0..1)
  #   2   — peaks at ~1.x get a clean ceiling of 2
  #   2.5 — peaks at ~2 get 25 instead of 40 (gridlines 0/6.25/12.5/...)
  #   4   — peaks at ~3 get 40 instead of 50 (gridlines 0/10/20/30/40)
  #         Without this, 29.4 → mantissa 2.94 → bucket 5 → axis 50,
  #         wasting ~40% of the chart's vertical space.
  #   5   — peaks at ~4 get 50
  #   7.5 — peaks at ~6 get 75 instead of 100 (avoids over-zoom 2x)
  #   10  — peaks at ~8-9 land at the next decade
  def nice_ceil(v)
    return 1 if v <= 0

    exp = Math.log10(v).floor
    factor = 10.0**exp
    mantissa = v / factor

    ceil = case mantissa
    when 0..1 then 1
    when 1..2 then 2
    when 2..2.5 then 2.5
    when 2.5..4 then 4
    when 4..5 then 5
    when 5..7.5 then 7.5
    when 7.5..10 then 10
    else 10
    end

    ceil * factor
  end

  # GAP_FACTOR — how many "median deltas" between consecutive points
  # we allow before declaring a gap. 3× picks up real outages (host
  # off for hours) without false-firing on the warehouse sync jitter
  # (a tick that took 35s instead of 30s isn't a gap, it's noise).
  GAP_FACTOR = 3.0

  # path_for — step-after (LOCF) path with gap detection.
  #
  # Splits the projected points into contiguous segments separated
  # by detected gaps (median × GAP_FACTOR threshold), then renders
  # each segment as a step-after staircase via `segment_path`.
  #
  # Why step-after instead of the previous Catmull-Rom bezier:
  # the chart's X axis is timestamp-based and non-uniform, so a
  # bezier connecting sparse samples drew a diagonal "ramp" that
  # implied gradual transition between them — actively misleading
  # when the truth was just "no data in between." See `segment_path`
  # for the full rationale + the path-shape math.
  #
  # Gap detection (segments_of) is still useful even with step:
  # for very long outages (host offline for hours), holding the
  # previous Y as a single flat line all the way to the post-outage
  # sample would imply "value stayed at X for hours" which is
  # equally dishonest. A real gap breaks the path so the chart
  # shows two disconnected servers of data with empty space between.
  def path_for(pts)
    builder = line? ? :linear_segment_path : :segment_path
    segments_of(pts).map { |seg| send(builder, seg) }.reject(&:empty?).join(" ")
  end

  # linear_segment_path — straight diagonal from point to point ("raio"), the
  # classic line-chart look the Line STYLE wants. area/bar keep the honest
  # STEP-AFTER (see segment_path); Line trades that for a flowing line the
  # operator explicitly opted into by picking it.
  def linear_segment_path(pts)
    return "" if pts.size < 2

    "M " + pts.map { |x, y| "#{x} #{y}" }.join(" L ")
  end

  # linear_area_path — the linear (raio) stroke closed down to the baseline, for
  # the Area multi fill. Mirrors linearPath+baseline in the JS resize rebuild.
  def linear_area_path(pts)
    return "" if pts.size < 2

    "#{linear_segment_path(pts)} L #{pts.last[0]} #{baseline_y} L #{pts.first[0]} #{baseline_y} Z"
  end

  # area_path_for — like path_for but each segment is independently
  # closed down to the baseline. Without this, the area fill would
  # close from the post-gap rightmost point ALL THE WAY LEFT to the
  # first sample, creating a translucent polygon covering the entire
  # gap region (visually pretending there was data). Per-segment
  # closure means each "server" of real data gets its own area fill
  # rooted to the baseline — the gap is honest empty space.
  def area_path_for(pts)
    segments_of(pts).map do |seg|
      next "" if seg.size < 2

      "#{segment_path(seg)} L #{seg.last[0]} #{baseline_y} L #{seg.first[0]} #{baseline_y} Z"
    end.reject(&:empty?).join(" ")
  end

  # segments_of — splits the projected points into contiguous runs
  # separated by gaps. A gap is any X distance > GAP_FACTOR × median
  # delta. The result is an Array of Arrays of points (each inner
  # Array is one segment ready for its own M+C+...+L baseline pass).
  #
  # Median-based threshold (not mean) so the appended latest point
  # — typically closer to the last bucket than buckets are to each
  # other — doesn't skew the cutoff. Catches multi-hour outages
  # without false-firing on natural sync jitter.
  def segments_of(pts)
    return [pts] if pts.size < 3

    threshold = gap_threshold_for(pts)
    segments = [[pts[0]]]

    (1...pts.size).each do |i|
      if (pts[i][0] - pts[i - 1][0]) > threshold
        segments << [pts[i]]
      else
        segments.last << pts[i]
      end
    end

    segments
  end

  # gap_threshold_for — derives the "this is a gap" cutoff from the
  # actual sample spacing in the series, not from a fixed value.
  def gap_threshold_for(pts)
    return Float::INFINITY if pts.size < 3

    deltas = (1...pts.size).map { |i| pts[i][0] - pts[i - 1][0] }
    median = deltas.sort[deltas.size / 2]
    median * GAP_FACTOR
  end

  # segment_path — single-segment STEP-AFTER (LOCF) path.
  #
  # Why step instead of the previous Catmull-Rom bezier:
  #
  # With time-bucketed metrics the X axis is non-uniform — a 1h
  # range showing two samples 70 minutes apart used to draw a
  # diagonal bezier ramp between them. That's actively misleading:
  # the operator sees "value smoothly climbed from 184 to 372 over
  # an hour" when the actual truth is "184 was the last measurement,
  # and the next measurement (whenever it arrived) was 372 — we
  # have NO data on what happened in between."
  #
  # Step-after semantics:
  #   - Hold the previous Y until the NEXT sample's X
  #   - Step vertically AT the next sample's X (instantaneous jump
  #     because that's where the new measurement landed)
  #
  # Path shape for samples A → B → C:
  #   M Ax Ay  L Bx Ay  L Bx By  L Cx By  L Cx Cy
  #              └ flat ┘└ jump ┘└ flat ┘└ jump ┘
  #
  # Standard monitoring-tool default (Grafana, Datadog, Prometheus
  # graph). Honest about sparse data; matches operator mental model
  # for both gauges ("last value held until refreshed") and counters
  # ("the bucket recorded this many; nothing recorded between
  # buckets means we don't know what was happening").
  #
  # Trade-off: for pure counters where "no sample = 0 traffic"
  # (req_count, bytes_out), LOCF holds the previous non-zero value
  # across an actual no-traffic gap, which is slightly less honest
  # than backfilling 0. That's a warehouse-side concern (see
  # MetricsWarehouse#aggregate_for); chart-side step is the right
  # default until/unless we add per-metric backfill semantics.
  def segment_path(pts)
    return "" if pts.size < 2

    d = "M #{pts[0][0]} #{pts[0][1]}"

    (1...pts.size).each do |i|
      prev_y = pts[i - 1][1]
      curr_x = pts[i][0]
      curr_y = pts[i][1]

      d += " L #{curr_x} #{prev_y} L #{curr_x} #{curr_y}"
    end

    d
  end

  # gradient_id — UNIQUE PER CHART INSTANCE (same reason as clip_id below).
  # It used to be stable per color, but a per-color id collides when several
  # same-color charts share the page: every `fill="url(#id)"` resolved to the
  # FIRST gradient in the DOM. Harmless while that first one is visible — but
  # collapsing its dashboard group (display:none) leaves the survivors pointing
  # at a paint server inside a hidden subtree, which Chromium won't apply, so
  # their area fill vanishes. `object_id` makes each chart reference its own
  # gradient. Memoised so the def and the `url(#…)` reference agree.
  def gradient_id
    @gradient_id ||= "voodu-metric-#{Digest::MD5.hexdigest("#{@color}-#{object_id}")[0, 8]}"
  end

  def bars_gradient_id
    @bars_gradient_id ||= "#{gradient_id}-bars"
  end

  # render_bars — one filled column per projected point, from its value down to
  # the baseline. Zero-height buckets are skipped (a gap, honestly empty). Bar
  # width ≈ the bucket spacing so dense data tiles into a solid fill and sparse
  # counts stand out as discrete columns.
  def render_bars(svg, pts, clip_id)
    bw = bar_width(pts)
    inner = (@width - pad_left - pad_right).to_f
    w_norm = (inner.positive? ? bw / inner : 0).round(5)

    # data-x-norm / data-w-norm let the metrics-chart controller reposition
    # each bar on resize (it rewrites the viewBox; without this the bars stay
    # in the old coordinate space and clip/vanish — the "flickering" bug).
    svg.g("clip-path": "url(##{clip_id})") do |g|
      # Baseline floor across the full width: a mostly-zero count series still
      # reads as a chart instead of an empty hole. Only in compact mode — with
      # axes, the frame baseline + y=0 gridline already draw the floor. hLine
      # target → the controller stretches its x2 on resize.
      unless @axes
        g.line(
          x1: pad_left, x2: @width - pad_right,
          y1: baseline_y, y2: baseline_y,
          stroke: @color, "stroke-opacity": "0.4", "stroke-width": "1",
          data: {metrics_chart_target: "hLine"}
        )
      end

      pts.each do |x, y|
        h = baseline_y - y
        next if h <= 0.4

        x_norm = (inner.positive? ? (x - pad_left) / inner : 0).round(5)
        # Solid fill (flat look) for now. The bars gradient (bars_gradient_id,
        # defined in `defs`) is intentionally kept so we can switch back to the
        # top-bright→bottom-soft fade by swapping this for `url(##{bars_gradient_id})`.
        g.rect(
          x: x.round(2), y: y.round(2),
          width: bw, height: h.round(2),
          rx: "0.75", fill: @color,
          data: {metrics_chart_target: "bar", x_norm: x_norm, w_norm: w_norm}
        )
      end
    end
  end

  # render_dots — a filled dot on each data point (line style), OUTSIDE the
  # clip so an edge dot isn't half-cropped. data-x-norm lets the controller
  # reposition each on resize (same mechanism as bars); cy is value-based and
  # unchanged by a width change.
  def render_dots(svg, pts)
    inner = (@width - pad_left - pad_right).to_f

    pts.each do |x, y|
      x_norm = (inner.positive? ? (x - pad_left) / inner : 0).round(5)

      svg.circle(
        cx: x.round(2), cy: y.round(2), r: "2.5", fill: @color,
        data: {metrics_chart_target: "dot", x_norm: x_norm}
      )
    end
  end

  # bar_width — the bucket spacing (minus a hair for a gap), clamped so a
  # single-point chart still draws a visible column.
  def bar_width(pts)
    return (@width - pad_left - pad_right) * 0.6 if pts.size < 2

    spacing = pts[1][0] - pts[0][0]
    [(spacing * 0.86).round(2), 1.0].max
  end

  # clip_id — UNIQUE PER CHART INSTANCE. The clipRect holds this chart's
  # own (resized) geometry, so its id must not collide with any other
  # chart on the page. Color + dimensions ISN'T unique enough: two panels
  # of the same metric on one page (e.g. Host CPU + FreeSwitch CPU, both
  # purple, same size — common when stacking dashboards) produced the
  # SAME id, so the browser resolved every `url(#id)` to the FIRST
  # clipPath in the DOM and clipped the later chart's curve to the wrong
  # rect — truncating it visually while its data stayed intact. `object_id`
  # makes each rendered chart's clip id distinct. Memoised so the def and
  # the `url(#…)` reference within one render agree.
  def clip_id
    @clip_id ||= begin
      seed = "#{@color}-#{@width}-#{@height}-#{pad_left}-#{pad_top}-#{pad_right}-#{pad_bottom}-#{object_id}"
      "voodu-metric-clip-#{Digest::MD5.hexdigest(seed)[0, 8]}"
    end
  end
end
