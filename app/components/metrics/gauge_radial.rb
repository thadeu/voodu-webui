# frozen_string_literal: true

# Components::Metrics::GaugeRadial — semicircle "fuel gauge" for a
# capacity / percent metric. The arc fills with the current %, the
# number sits big in the center, and the absolute value (e.g.
# "13.2 / 42 GB") below it. The fill tints AMBER past 70% and RED
# past 90% — same thresholds as the pod CPU bar — so a resource
# nearing its ceiling jumps out without reading the axis.
#
# Rendered by Components::Metrics::ChartCard when chart_type is
# "gauge_radial". Pure server SVG (matches Chart's no-JS approach).
# ChartCard does all the formatting; this component only draws.
class Components::Metrics::GaugeRadial < Components::Base
  R = 76   # arc radius
  CX = 100  # center x
  CY = 96   # baseline y the arc springs up from
  SW = 16   # arc stroke width

  # percent — true (default): the center reads the fill "%". false: the center
  # reads `value_label` (the raw value) instead — for a count, where "% of the
  # peak" is confusing, the arc still fills but the number is the count itself.
  def initialize(pct:, color:, sub_label: nil, max_w: 220, percent: true, value_label: nil)
    @pct = clamp(pct.to_f)
    @color = color
    @sub_label = sub_label
    @max_w = max_w
    @percent = percent
    @value_label = value_label.to_s
  end

  def view_template
    arc = Math::PI * R
    fill = (@pct / 100.0) * arc

    svg(
      viewBox: "0 0 200 116",
      class: "block mx-auto w-full h-auto", style: "max-width: #{@max_w}px;", fill: "none",
      role: "img", "aria-label": "#{@pct.round}%"
    ) do |s|
      s.path(
        d: arc_path, stroke: "var(--voodu-surface-3)",
        "stroke-width": SW, "stroke-linecap": "round"
      )
      s.path(
        d: arc_path, stroke: fill_color,
        "stroke-width": SW, "stroke-linecap": "round",
        "stroke-dasharray": "#{fill.round(2)} #{arc.round(2)}"
      )
      s.text(
        x: CX, y: CY - 6, "text-anchor": "middle",
        fill: "var(--voodu-text)", "font-size": "30", "font-weight": "600",
        "font-family": "var(--voodu-font-sans, system-ui, sans-serif)"
      ) { center_label }

      if @sub_label.present?
        s.text(
          x: CX, y: CY + 13, "text-anchor": "middle",
          fill: "var(--voodu-muted)", "font-size": "12",
          "font-family": "var(--voodu-font-mono, ui-monospace, monospace)"
        ) { @sub_label }
      end
    end
  end

  private

  def arc_path
    "M #{CX - R} #{CY} A #{R} #{R} 0 0 1 #{CX + R} #{CY}"
  end

  # Threshold tints mirror Components::Overview::PodCard#cpu_color
  # (>90 red, >70 amber) so "near full" reads the same site-wide.
  def fill_color
    return "var(--voodu-red)" if @pct >= 90
    return "var(--voodu-amber)" if @pct >= 70

    @color
  end

  # center_label — the % fill, or the raw value when percent: false.
  def center_label
    (!@percent && @value_label.present?) ? @value_label : pct_label
  end

  def pct_label
    # String#% — `format`/`sprintf` resolve to a shadowed 0-arg helper
    # in the Phlex component context (same reason PodCard uses "%.1f" % v).
    (@pct < 10) ? "#{"%.1f" % @pct}%" : "#{@pct.round}%"
  end

  def clamp(v)
    return 0.0 if v.negative?
    return 100.0 if v > 100

    v
  end
end
