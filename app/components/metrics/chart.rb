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
#        data-metrics-chart-color-value="#7c5cff"
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
  PAD_LEFT_FULL    = 44   # room for y-axis labels
  PAD_RIGHT_FULL   = 12
  PAD_TOP_FULL     = 14
  PAD_BOTTOM_FULL  = 22   # room for x-axis labels

  PAD_LEFT_COMPACT   = 4
  PAD_RIGHT_COMPACT  = 4
  PAD_TOP_COMPACT    = 4
  PAD_BOTTOM_COMPACT = 4

  Y_TICKS = 5
  X_TICKS = 5

  # axes: true → big chart with full Y/X labels + gridlines
  #       false → compact (sparkline-like): same curve + same
  #       hover crosshair + tooltip, no visible axes. Used by
  #       Overview StatCards and Pod show StatCards so all three
  #       chart surfaces (Overview, Pod show, /metrics) share
  #       the same SVG/JS rendering engine.
  def initialize(points:, color:, unit:, label:, range_ms:, height: 200, width: 600, axes: true)
    @points   = Array(points)
    @color    = color
    @unit     = unit
    @label    = label
    @range_ms = range_ms.to_i
    @height   = height
    @width    = width
    @axes     = axes
  end

  def pad_left;   @axes ? PAD_LEFT_FULL   : PAD_LEFT_COMPACT;   end
  def pad_right;  @axes ? PAD_RIGHT_FULL  : PAD_RIGHT_COMPACT;  end
  def pad_top;    @axes ? PAD_TOP_FULL    : PAD_TOP_COMPACT;    end
  def pad_bottom; @axes ? PAD_BOTTOM_FULL : PAD_BOTTOM_COMPACT; end

  def view_template
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
    # warming up, brand-new island, or very short range). The
    # operator already sees a meaningful value in the StatCard
    # headline pulled from that same point; the chart should render
    # a flat line at that level rather than say "no data" (which
    # contradicts the headline + min/avg/max next to it). We
    # duplicate the point so the curve has 2 vertices to draw.
    if @points.size == 1
      only = @points.first
      @points = [only, only]
    end

    pts    = projected_points
    y_max  = nice_ceil(raw_max * 1.18)
    x_min, x_max = time_bounds

    div(
      class: "relative w-full",
      data: {
        controller: "metrics-chart",
        metrics_chart_points_value: points_for_js.to_json,
        metrics_chart_color_value:  @color,
        metrics_chart_unit_value:   @unit,
        metrics_chart_label_value:  @label,
        metrics_chart_width_value:  @width,
        metrics_chart_height_value: @height,
        metrics_chart_pad_left_value: pad_left,
        metrics_chart_pad_right_value: pad_right,
        metrics_chart_pad_top_value: pad_top,
        metrics_chart_pad_bottom_value: pad_bottom
      }
    ) do
      svg(
        width: "100%", height: @height,
        viewBox: "0 0 #{@width} #{@height}",
        preserveAspectRatio: "none",
        class: "block overflow-visible",
        style: "touch-action: pan-y;"
      ) do |s|
        s.defs do
          s.linearGradient(id: gradient_id, x1: 0, y1: 0, x2: 0, y2: 1) do
            s.stop(offset: "0%",   "stop-color": @color, "stop-opacity": "0.30")
            s.stop(offset: "100%", "stop-color": @color, "stop-opacity": "0")
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
              height: @height - pad_top - pad_bottom
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

        d_line = path_for(pts)
        d_area = area_path_for(pts)

        # Both fill and stroke go through the clip so an overshoot
        # below the baseline (or above the top) is invisibly cropped.
        s.g("clip-path": "url(##{clip_id})") do
          s.path(d: d_area, fill: "url(##{gradient_id})")
          s.path(
            d: d_line, fill: "none", stroke: @color, "stroke-width": "1.5",
            "stroke-linecap": "round", "stroke-linejoin": "round"
          )
        end

        # Frame baseline — solid line at the bottom of the chart
        # area, distinct from the dashed y=0 gridline since the
        # chart's bottom often clips into the x-axis label band.
        # Compact mode skips it (no axis area to demarcate).
        if @axes
          s.line(
            x1: pad_left, x2: @width - pad_right,
            y1: baseline_y, y2: baseline_y,
            stroke: "var(--voodu-border)"
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
            action: "mousemove->metrics-chart#move mouseleave->metrics-chart#leave"
          }
        )
      end
    end
  end

  private

  # points_for_js — pre-projected points the Stimulus controller
  # consumes for hover nearest-x lookup. Keeps the coordinate math
  # in one place (server-side) and lets the JS stay tiny: find
  # nearest by x, position tooltip + crosshair using the same px
  # the SVG already painted.
  def points_for_js
    pts    = projected_points
    @points.each_with_index.map do |p, i|
      {
        ts:        p[:ts],
        value:     p[:value],
        formatted: p[:formatted],
        x:         pts[i][0].round(2),
        y:         pts[i][1].round(2)
      }
    end
  end

  def projected_points
    y_max = nice_ceil(raw_max * 1.18)
    x_min, x_max = time_bounds

    inner_w = (@width - pad_left - pad_right).to_f
    inner_h = (@height - pad_top - pad_bottom).to_f
    x_span  = [(x_max - x_min).to_f, 1.0].max
    y_span  = [y_max.to_f, 0.0001].max

    @points.map do |p|
      t = parse_ts_ms(p[:ts])
      x = pad_left + ((t - x_min) / x_span) * inner_w
      y = pad_top  + (1 - (p[:value].to_f / y_span)) * inner_h
      [x, y]
    end
  end

  def raw_max
    @points.map { |p| p[:value].to_f }.max
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
        "stroke-opacity": i.zero? ? "0" : "0.5"
      )

      svg.text(
        x: pad_left - 6, y: y + 3.5,
        "text-anchor": "end",
        "font-size": "10",
        fill: "var(--voodu-muted-2)",
        "font-family": "var(--voodu-font-mono, ui-monospace, monospace)"
      ) { format_axis_number(v) }
    end
  end

  # render_x_axis — 5 timestamps along the bottom. Format adapts
  # to the range (HH:MM:SS for ≤1h, HH:MM for ≤24h, MM/DD beyond).
  # Same logic as fmtAxisTime in pages-metrics.jsx so the labels
  # match the inspiration.
  def render_x_axis(svg, x_min, x_max)
    span = x_max - x_min

    (0..(X_TICKS - 1)).each do |i|
      t = i.to_f / (X_TICKS - 1)
      ts_ms = x_min + t * span
      ts = Time.at(ts_ms / 1000.0).utc

      svg.text(
        x: pad_left + t * (@width - pad_left - pad_right),
        y: @height - 5,
        "text-anchor": "middle",
        "font-size": "10",
        fill: "var(--voodu-muted-2)",
        "font-family": "var(--voodu-font-mono, ui-monospace, monospace)"
      ) { format_axis_time(ts) }
    end
  end

  # format_axis_time — pick format that fits the chart's range:
  #   ≤ 1h    → HH:MM:SS
  #   ≤ 24h   → HH:MM
  #   beyond  → MM/DD
  def format_axis_time(ts)
    if @range_ms <= 60 * 60 * 1000
      ts.strftime("%H:%M:%S")
    elsif @range_ms <= 24 * 60 * 60 * 1000
      ts.strftime("%H:%M")
    else
      ts.strftime("%m/%d")
    end
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
  # (1, 2, 2.5, 5, 10 × 10^n). Ported from pages-metrics.jsx.
  # Without this the Y-axis labels would be ugly raw numbers like
  # 23.7, 47.4, 71.1; with it we get 25, 50, 75, 100.
  def nice_ceil(v)
    return 1 if v <= 0

    exp = Math.log10(v).floor
    factor = 10.0**exp
    mantissa = v / factor

    ceil = case mantissa
           when 0..1   then 1
           when 1..2   then 2
           when 2..2.5 then 2.5
           when 2.5..5 then 5
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
  # shows two disconnected islands of data with empty space between.
  def path_for(pts)
    segments_of(pts).map { |seg| segment_path(seg) }.reject(&:empty?).join(" ")
  end

  # area_path_for — like path_for but each segment is independently
  # closed down to the baseline. Without this, the area fill would
  # close from the post-gap rightmost point ALL THE WAY LEFT to the
  # first sample, creating a translucent polygon covering the entire
  # gap region (visually pretending there was data). Per-segment
  # closure means each "island" of real data gets its own area fill
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
    segments  = [[pts[0]]]

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

  # gradient_id — stable per color. Same MD5 trick as Sparkline to
  # avoid the `var(--…)` parens-in-id browser crash.
  def gradient_id
    "voodu-metric-#{Digest::MD5.hexdigest(@color)[0, 8]}"
  end

  # clip_id — per-(color, dimensions) so multiple charts on the
  # same page don't share a clip rect (a stale one would clip to
  # the wrong area). Color alone wouldn't be enough — Overview
  # CPU + Metrics CPU both purple but have different sizes.
  def clip_id
    seed = "#{@color}-#{@width}-#{@height}-#{pad_left}-#{pad_top}-#{pad_right}-#{pad_bottom}"
    "voodu-metric-clip-#{Digest::MD5.hexdigest(seed)[0, 8]}"
  end
end
