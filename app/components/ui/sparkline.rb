# frozen_string_literal: true

# Components::UI::Sparkline — area + stroke time-series chart with
# per-point hover tooltips.
#
# Anatomy:
#
#   ┌──────────────────────────────────┐
#   │ ╲       ╱╲                  ╱╲   │   smoothed area + stroke
#   │  ╲     ╱  ╲                ╱  ●  │   pulse dot on the last point
#   │   ╲___╱    ╲______________╱     │
#   └──────────────────────────────────┘
#
# Hover behaviour:
#   - One invisible vertical strip per point covers the chart.
#   - mouseenter / mousemove fires the sparkline-tooltip Stimulus
#     controller, which:
#       1. positions a fixed-position tooltip above the hovered point
#       2. draws a small dot at the point + a dashed vertical line
#       3. shows the formatted value + the timestamp.
#   - mouseleave hides both.
#
# Data shape:
#
#   points: [{ ts: "2026-05-24T09:00:00Z", value: 12.4, formatted: "12.4%" }, ...]
#
# `ts` is the ISO timestamp; `value` the raw numeric (drives the
# curve); `formatted` is what the tooltip shows. Format-on-Rails-side
# keeps the controller unaware of units (%, MB, GB) — that knowledge
# stays in MetricsData where the metric name is in scope.
#
# Empty / single-point data → renders nothing (caller's StatCard
# already hides the wrapper when `points.blank?`).
class Components::UI::Sparkline < Components::Base
  PAD = 4

  def initialize(points:, color: "#7c5cff", width: 220, height: 56, show_fill: true, stroke: 1.5)
    @points    = Array(points).map { |p| normalize(p) }
    @color     = color
    @width     = width
    @height    = height
    @show_fill = show_fill
    @stroke    = stroke
  end

  def view_template
    return if @points.size < 2

    pts    = projected_points
    d_line = path_for(pts)
    d_area = "#{d_line} L #{pts.last[0]} #{@height} L #{pts.first[0]} #{@height} Z"
    gid    = gradient_id

    svg(
      width: "100%", height: @height,
      viewBox: "0 0 #{@width} #{@height}",
      preserveAspectRatio: "none",
      class: "block overflow-visible",
      data: { controller: "sparkline-tooltip" },
      style: "--voodu-spark-color: #{@color};"
    ) do |s|
      s.defs do
        s.linearGradient(id: gid, x1: 0, x2: 0, y1: 0, y2: 1) do
          s.stop(offset: "0%",   "stop-color": @color, "stop-opacity": "0.32")
          s.stop(offset: "100%", "stop-color": @color, "stop-opacity": "0")
        end
      end

      s.path(d: d_area, fill: "url(##{gid})") if @show_fill
      s.path(
        d: d_line, fill: "none",
        stroke: @color, "stroke-width": @stroke,
        "stroke-linecap": "round", "stroke-linejoin": "round"
      )

      # Y-axis labels overlay — small muted text in the corners
      # showing the data range. Top-right: max, bottom-right: min.
      # Renders the formatted value (from MetricsData) so units
      # stay consistent ("18.7%" / "805.3 MB" / etc.).
      axis_labels(s)

      # Always-on dot at the latest point — the "current value"
      # affordance from the original sparkline. Stays put when the
      # operator isn't hovering; gets hidden by the Stimulus
      # controller while hovering (so the focus marker on the
      # hovered point doesn't clash).
      cx, cy = pts.last
      s.circle(
        cx: cx, cy: cy, r: 5, fill: @color, opacity: "0.18",
        data: { sparkline_tooltip_target: "tailDot" }
      )
      s.circle(
        cx: cx, cy: cy, r: 2.5, fill: @color,
        data: { sparkline_tooltip_target: "tailDot" }
      )

      # Per-point hover strips. Invisible, full-height, mouse
      # events feed the Stimulus controller. preserveAspectRatio
      # is `none` so widths scale 1:1 with viewBox even when the
      # SVG is `width: 100%` — the strip's x stays aligned with
      # its point's underlying viewBox x.
      hover_strips(s, pts)
    end
  end

  private

  # normalize — accept rich `{ts:, value:, formatted:}` or a bare
  # numeric. The bare path keeps the legacy `[Float]` call sites
  # (anything not yet migrated to MetricsData#points_for) working;
  # tooltip just shows the rounded value without a timestamp.
  def normalize(p)
    return p if p.is_a?(Hash)

    { ts: nil, value: p.to_f, formatted: p.to_f.round(2).to_s }
  end

  def projected_points
    min = @points.map { |p| p[:value] }.min
    max = @points.map { |p| p[:value] }.max
    range = [max - min, 0.0001].max
    dx = (@width - PAD * 2).to_f / (@points.size - 1)

    @points.each_with_index.map do |p, i|
      t = (p[:value] - min) / range
      [PAD + i * dx, @height - PAD - t * (@height - PAD * 2)]
    end
  end

  # path_for — Catmull-Rom → cubic bezier smoothing.
  #
  # Same JS→Ruby porting gotcha as Components::Metrics::Chart:
  # `pts[-1]` in Ruby returns the last element, NOT nil. The
  # naive `pts[i - 1] || pts[i]` fallback never triggers, and
  # the curve's first segment derives its control point from the
  # span between the first and last points — bowing the line
  # out of the chart box at the start. Explicit bounds checks
  # below.
  def path_for(pts)
    d = "M #{pts[0][0]} #{pts[0][1]}"

    (0...pts.size - 1).each do |i|
      p0 = i.zero? ? pts[i] : pts[i - 1]
      p1 = pts[i]
      p2 = pts[i + 1]
      p3 = (i + 2 < pts.size) ? pts[i + 2] : p2

      cp1x = p1[0] + (p2[0] - p0[0]) / 6.0
      cp1y = p1[1] + (p2[1] - p0[1]) / 6.0
      cp2x = p2[0] - (p3[0] - p1[0]) / 6.0
      cp2y = p2[1] - (p3[1] - p1[1]) / 6.0

      d += " C #{cp1x} #{cp1y}, #{cp2x} #{cp2y}, #{p2[0]} #{p2[1]}"
    end

    d
  end

  # hover_strips — one rect per point, mid-aligned. Widths overlap
  # at edges (each strip claims half the slot to its left + half to
  # its right) so the mouse never falls between strips.
  def hover_strips(svg, pts)
    return if pts.size < 2

    slot_w = (pts.last[0] - pts.first[0]).to_f / (pts.size - 1)
    half   = slot_w / 2.0

    @points.each_with_index do |p, i|
      x = pts[i][0] - half
      w = slot_w

      # Clamp the edge strips so they don't poke past the viewBox.
      if i.zero?
        x = 0
        w = pts[i][0] + half
      end

      if i == @points.size - 1
        w = @width - x
      end

      svg.rect(
        x: x, y: 0, width: w, height: @height,
        fill: "transparent", "pointer-events": "all",
        # Cursor cue so operator notices the chart is interactive.
        style: "cursor: crosshair;",
        data: {
          sparkline_tooltip_target: "strip",
          action: "mouseenter->sparkline-tooltip#show mouseleave->sparkline-tooltip#hide",
          ts: p[:ts] || "",
          value: p[:value],
          formatted: p[:formatted],
          # Pre-compute the point coordinates so the JS doesn't
          # need to re-project — saves doing the bezier math twice.
          point_x: pts[i][0],
          point_y: pts[i][1]
        }
      )
    end
  end

  # axis_labels — tiny muted text overlay in the chart corners
  # showing min/max of the visible series. Caller's StatCard
  # already has the time-range chip ("[1h]"), so we don't repeat
  # the x-axis here; just the y range.
  #
  # Positioned with text-anchor="end" so the values right-align
  # against the SVG's right edge regardless of how long the
  # formatted string is. Background is omitted because the values
  # land in the corners where the curve almost never reaches —
  # readable against the area gradient.
  def axis_labels(svg)
    max_p = @points.max_by { |p| p[:value] }
    min_p = @points.min_by { |p| p[:value] }

    return if max_p[:value] == min_p[:value]

    # x=@width - PAD so the text right-aligns near the right edge.
    # Y positions hug top and bottom but leave room for the
    # 10px-tall text glyph itself.
    label_attrs = {
      "text-anchor":     "end",
      "fill":            "var(--voodu-muted-2, #6c7790)",
      "font-size":       "9px",
      "font-family":     "var(--voodu-font-mono, ui-monospace, monospace)",
      "pointer-events":  "none"
    }

    svg.text(x: @width - PAD, y: 10, **label_attrs) { max_p[:formatted] }
    svg.text(x: @width - PAD, y: @height - 2, **label_attrs) { min_p[:formatted] }
  end

  # gradient_id — stable SVG-safe id derived from the color string.
  # See the long-form comment in git history for the parens-in-id
  # gotcha that this avoids; short version: CSS var colors break
  # the naive `delete("#")` approach.
  def gradient_id
    "voodu-spark-#{Digest::MD5.hexdigest(@color)[0, 8]}"
  end
end
