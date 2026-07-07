# frozen_string_literal: true

require "test_helper"

class Components::Metrics::ChartTest < ActiveSupport::TestCase
  BASE = {points: [], unit: "%", label: "CPU", range_ms: 900_000}.freeze

  # Two charts of the SAME metric render the same color + dimensions
  # (e.g. Host CPU + FreeSwitch CPU, both purple, both full-size when two
  # dashboards stack). Their clipPath ids must still differ — otherwise
  # the browser resolves every `url(#id)` to the FIRST clipPath in the
  # DOM and clips the later chart's curve to the wrong rect, truncating
  # it. Regression for the "last stacked dashboard's chart cut short" bug.
  test "same-color, same-size charts get distinct clip ids" do
    a = Components::Metrics::Chart.new(color: "var(--voodu-purple)", **BASE)
    b = Components::Metrics::Chart.new(color: "var(--voodu-purple)", **BASE)

    assert_not_equal a.send(:clip_id), b.send(:clip_id),
      "identical-looking charts must not share a clipPath id"
  end

  # The def (`<clipPath id=…>`) and the reference (`url(#…)`) are computed
  # by separate calls within one render — they must agree.
  test "clip_id is stable within a single instance" do
    c = Components::Metrics::Chart.new(color: "var(--voodu-blue)", **BASE)

    assert_equal c.send(:clip_id), c.send(:clip_id)
  end

  POINTS = [
    {ts: "2026-06-16T12:00:00Z", value: 10},
    {ts: "2026-06-16T12:05:00Z", value: 20}
  ].freeze

  # Brush-to-zoom (drag a range → reload at range=custom) is area/line-only.
  test "area charts wire brush-to-zoom on the hover overlay" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", **BASE.merge(points: POINTS)).call

    assert_includes html, "mousedown->metrics-chart#brushStart",
      "area chart overlay must enable brush-to-zoom"
    assert_includes html, "metrics-chart#move", "hover stays wired"
  end

  # Bar charts are discrete-count buckets — a sub-range zoom doesn't map, so no brush.
  test "bar charts do NOT wire brush-to-zoom" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", **BASE.merge(points: POINTS, bars: true)).call

    assert_not_includes html, "mousedown->metrics-chart#brushStart"
    assert_includes html, "metrics-chart#move", "hover still wired on bars"
  end

  # In the modal, brush-to-zoom must re-fetch in place instead of navigating
  # the whole page (which tears the modal down). The controller keys on the
  # PRESENCE of the zoom-url value to pick that path — so it must be emitted
  # when given and ABSENT (not empty) otherwise.
  test "zoom_url emits the modal re-fetch value when given" do
    html = Components::Metrics::Chart.new(
      color: "var(--voodu-green)",
      zoom_url: "/o/s/metrics/chart?metric=cpu_percent",
      **BASE.merge(points: POINTS)
    ).call

    assert_includes html, "data-metrics-chart-zoom-url-value"
    assert_includes html, "/o/s/metrics/chart?metric=cpu_percent"
  end

  test "zoom_url is absent on the grid (no in-modal re-fetch)" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", **BASE.merge(points: POINTS)).call

    assert_not_includes html, "data-metrics-chart-zoom-url-value"
  end
end
