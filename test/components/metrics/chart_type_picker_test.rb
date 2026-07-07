# frozen_string_literal: true

require "test_helper"

# Covers the modal's chart-type dropdown: the three options, the active state,
# the clean-URL default (area omits chart_type), and turbo_stream wiring.
class Components::Metrics::ChartTypePickerTest < ActiveSupport::TestCase
  def render_picker(**opts)
    Components::Metrics::ChartTypePicker.new(base_path: "/o/s/metrics/chart", **opts).call
  end

  test "offers Area / Radial / Linear" do
    html = render_picker(current: "area")

    assert_includes html, ">Area<"
    assert_includes html, ">Radial<"
    assert_includes html, ">Linear<"
  end

  test "the trigger shows the active type's label" do
    html = render_picker(current: "gauge_radial")

    assert_includes html, "type "
    assert_match(/text-voodu-text">Radial</, html)
  end

  test "area omits chart_type (clean default); gauges set it explicitly" do
    html = render_picker(current: "area", extra_params: {metric: "cpu_percent"})

    assert_includes html, 'href="/o/s/metrics/chart?metric=cpu_percent"'
    assert_includes html, "chart_type=gauge_radial"
    assert_includes html, "chart_type=gauge_linear"
  end

  test "the active option gets the accent chrome + check" do
    html = render_picker(current: "gauge_linear")

    assert_match(/bg-voodu-accent-dim[^"]*"[^>]*>\s*<span[^>]*font-semibold[^>]*>Linear/m, html)
  end

  test "turbo_stream mode emits data-turbo-stream on the rows" do
    html = render_picker(current: "area", turbo_stream: true)

    assert_includes html, 'data-turbo-stream="true"'
  end

  test "grid mode (no turbo_stream) does not emit turbo-stream on rows" do
    html = render_picker(current: "area")

    assert_not_includes html, "data-turbo-stream"
  end
end
