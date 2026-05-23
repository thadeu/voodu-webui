# frozen_string_literal: true

# Components::UI::Sparkline — area + stroke time-series chart.
#
# Pure SVG, ported 1:1 from the inspiration HTML's <Sparkline> component
# (parts.jsx). Catmull-Rom → cubic bezier smoothing gives the curve a
# natural feel even with only ~30 sample points.
#
# Behaviour:
#   - Pad of 4 keeps the curve from kissing the SVG edge.
#   - Area fill uses a vertical linear gradient at 0..32% opacity.
#   - Last point gets a dot + halo so the "current value" reads at a
#     glance.
#
# data: Array of numerics (CPU %, mem %, requests/sec — anything).
# color: any CSS color string. Defaults to the voodu accent.
class Components::UI::Sparkline < Components::Base
  def initialize(data:, color: "#7c5cff", width: 220, height: 56, show_fill: true, stroke: 1.5)
    @data      = Array(data).map(&:to_f)
    @color     = color
    @width     = width
    @height    = height
    @show_fill = show_fill
    @stroke    = stroke
  end

  def view_template
    return if @data.size < 2

    pts = points
    d_line = path_for(pts)
    d_area = "#{d_line} L #{pts.last[0]} #{@height} L #{pts.first[0]} #{@height} Z"
    gid = "voodu-spark-#{@color.delete('#')}"

    svg(
      width: "100%", height: @height,
      viewBox: "0 0 #{@width} #{@height}",
      preserveAspectRatio: "none"
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

      # Last-point dot + halo.
      cx, cy = pts.last
      s.circle(cx: cx, cy: cy, r: 5,   fill: @color, opacity: "0.18")
      s.circle(cx: cx, cy: cy, r: 2.5, fill: @color)
    end
  end

  private

  def points
    pad = 4
    min = @data.min
    max = @data.max
    range = [max - min, 0.0001].max
    dx = (@width - pad * 2).to_f / (@data.size - 1)

    @data.each_with_index.map do |v, i|
      t = (v - min) / range
      [pad + i * dx, @height - pad - t * (@height - pad * 2)]
    end
  end

  def path_for(pts)
    d = "M #{pts[0][0]} #{pts[0][1]}"

    (0...pts.size - 1).each do |i|
      p0 = pts[i - 1] || pts[i]
      p1 = pts[i]
      p2 = pts[i + 1]
      p3 = pts[i + 2] || p2

      cp1x = p1[0] + (p2[0] - p0[0]) / 6.0
      cp1y = p1[1] + (p2[1] - p0[1]) / 6.0
      cp2x = p2[0] - (p3[0] - p1[0]) / 6.0
      cp2y = p2[1] - (p3[1] - p1[1]) / 6.0

      d += " C #{cp1x} #{cp1y}, #{cp2x} #{cp2y}, #{p2[0]} #{p2[1]}"
    end

    d
  end
end
