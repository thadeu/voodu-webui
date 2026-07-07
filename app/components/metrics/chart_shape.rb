# frozen_string_literal: true

# Components::Metrics::ChartShape — the little glyph for a chart TYPE
# (area / bars / line / radial / linear). ONE source of truth for the shape
# icons, shared by the dashboard builder's shape chips and the expand modal's
# chart-type dropdown (and whatever comes next).
#
# `css` sizes it: the default "w-full h-full" fills the big builder chip
# preview; a small "w-6 h-4" sits inline before a dropdown label.
#
# Everything draws with currentColor so the glyph inherits the surrounding
# text color — the builder sets it live to the metric hue, a dropdown row uses
# its own text/accent color.
class Components::Metrics::ChartShape < Components::Base
  # [{value, label, gauge}] for the time-series + gauge shapes, in display
  # order. The canonical list the ChartTypePicker and the builder's metric
  # shape chips both iterate. `gauge: true` ones need a metric with a ceiling.
  METRIC_TYPES = [
    {value: "area", label: "Area", gauge: false},
    {value: "bars", label: "Bar", gauge: false},
    {value: "line", label: "Line", gauge: false},
    {value: "gauge_radial", label: "Radial", gauge: true},
    {value: "gauge_linear", label: "Linear", gauge: true}
  ].freeze

  LABELS = METRIC_TYPES.to_h { |t| [t[:value], t[:label]] }.freeze

  def initialize(type:, css: "w-full h-full")
    @type = type.to_s
    @css = css
  end

  def view_template
    case @type
    when "bars" then bars
    when "line" then line
    when "gauge_radial" then radial
    when "gauge_linear" then linear
    else area
    end
  end

  private

  def base_svg(fill: "none", &)
    svg(viewBox: "0 0 80 40", class: @css, fill: fill, "aria-hidden": "true", preserveAspectRatio: "xMidYMid meet", &)
  end

  def area
    base_svg do |s|
      s.polygon(points: "0,28 20,18 40,22 60,10 80,16 80,40 0,40", fill: "currentColor", opacity: "0.18")
      s.polyline(points: "0,28 20,18 40,22 60,10 80,16", stroke: "currentColor", "stroke-width": "2.5", "stroke-linejoin": "round", "stroke-linecap": "round")
    end
  end

  def bars
    base_svg do |s|
      [[10, 22], [26, 12], [42, 18], [58, 8]].each do |x, y|
        s.rect(x: x, y: y, width: "9", height: 36 - y, rx: "1.5", fill: "currentColor", opacity: "0.85")
      end
    end
  end

  def line
    pts = [[8, 29], [30, 15], [52, 23], [72, 9]]

    base_svg do |s|
      s.polyline(points: pts.map { |x, y| "#{x},#{y}" }.join(" "), stroke: "currentColor", "stroke-width": "2.5", "stroke-linejoin": "round", "stroke-linecap": "round")
      pts.each { |x, y| s.circle(cx: x, cy: y, r: "3", fill: "currentColor") }
    end
  end

  def radial
    base_svg do |s|
      s.path(d: "M14 34 A26 26 0 0 1 66 34", stroke: "var(--voodu-border-2)", "stroke-width": "5", "stroke-linecap": "round")
      s.path(d: "M14 34 A26 26 0 0 1 52 12", stroke: "currentColor", "stroke-width": "5", "stroke-linecap": "round")
    end
  end

  def linear
    base_svg(fill: nil) do |s|
      s.rect(x: "8", y: "17", width: "64", height: "7", rx: "3.5", fill: "var(--voodu-border-2)")
      s.rect(x: "8", y: "17", width: "42", height: "7", rx: "3.5", fill: "currentColor")
    end
  end
end
