# frozen_string_literal: true

require "test_helper"

# ChartShape is the one glyph source for a chart type, shared by the builder
# chips and the modal dropdown. Each type must draw its own distinct shape.
class Components::Metrics::ChartShapeTest < ActiveSupport::TestCase
  def render_shape(type, **opts)
    Components::Metrics::ChartShape.new(type: type, **opts).call
  end

  test "bars draws columns (rects), no line" do
    html = render_shape("bars")

    assert_includes html, "<rect"
    assert_not_includes html, "<polyline"
  end

  test "line draws a polyline + dots (circles), no fill polygon" do
    html = render_shape("line")

    assert_includes html, "<polyline"
    assert_includes html, "<circle"
    assert_not_includes html, "<polygon"
  end

  test "area draws a filled polygon + a stroke, no dots" do
    html = render_shape("area")

    assert_includes html, "<polygon"
    assert_includes html, "<polyline"
    assert_not_includes html, "<circle"
  end

  test "radial + linear draw the gauge glyphs" do
    assert_includes render_shape("gauge_radial"), "<path"
    assert_includes render_shape("gauge_linear"), "<rect"
  end

  test "an unknown type falls back to area" do
    assert_includes render_shape("nonsense"), "<polygon"
  end

  test "css sizes the glyph" do
    assert_includes render_shape("line", css: "w-6 h-4"), "w-6 h-4"
  end

  # The canonical list the picker + builder share, in order.
  test "METRIC_TYPES lists the five shapes with labels + gauge flags" do
    values = Components::Metrics::ChartShape::METRIC_TYPES.map { |t| t[:value] }

    assert_equal %w[area bars line gauge_radial gauge_linear], values
    assert_equal "Bar", Components::Metrics::ChartShape::LABELS["bars"]
    gauges = Components::Metrics::ChartShape::METRIC_TYPES.select { |t| t[:gauge] }.map { |t| t[:value] }
    assert_equal %w[gauge_radial gauge_linear], gauges
  end
end
