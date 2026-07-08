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

  # Brush-to-zoom (drag a range → reload at range=custom) is inherited by every
  # draw style — a time sub-range maps the same for area, bar, or line.
  test "area charts wire brush-to-zoom on the hover overlay" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", **BASE.merge(points: POINTS)).call

    assert_includes html, "mousedown->metrics-chart#brushStart",
      "area chart overlay must enable brush-to-zoom"
    assert_includes html, "metrics-chart#move", "hover stays wired"
  end

  test "bar charts also wire brush-to-zoom (behavior inherited across styles)" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", **BASE.merge(points: POINTS, style: :bars)).call

    assert_includes html, "mousedown->metrics-chart#brushStart", "bars must enable brush too"
    assert_includes html, "metrics-chart#move", "hover wired on bars"
    assert_includes html, 'data-metrics-chart-target="bar"', "bars render columns"
  end

  # Line style = straight point-to-point stroke ("raio") + a dot per point,
  # NO area fill, and LINEAR interpolation (not the area's step-after).
  test "line charts draw a dot per point + a straight stroke, no fill, linear interp" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", **BASE.merge(points: POINTS, style: :line)).call

    assert_includes html, 'data-metrics-chart-target="dot"', "line style renders dots"
    assert_includes html, 'data-metrics-chart-target="line"', "line style renders the stroke"
    assert_not_includes html, 'data-metrics-chart-target="area"', "line style has NO fill"
    assert_includes html, 'data-metrics-chart-interp-value="linear"', "line uses straight (raio) interpolation"
    assert_includes html, "mousedown->metrics-chart#brushStart", "line inherits brush"
  end

  # Area keeps its fill + step-after (LOCF) interpolation; no stray dots.
  test "area charts fill, step-after interp, no dots" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", **BASE.merge(points: POINTS)).call

    assert_includes html, 'data-metrics-chart-target="area"', "area style fills"
    assert_includes html, 'data-metrics-chart-interp-value="step"', "area keeps honest step-after"
    assert_not_includes html, 'data-metrics-chart-target="dot"', "area draws no dots"
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

  # Multi-series (pilot: Line) — one line per series on shared axes, no fill.
  SERIES = [
    {label: "a1", color: "var(--voodu-purple)", points: [{ts: "2026-06-16T12:00:00Z", value: 10}, {ts: "2026-06-16T12:05:00Z", value: 20}]},
    {label: "b2", color: "var(--voodu-blue)", points: [{ts: "2026-06-16T12:00:00Z", value: 5}, {ts: "2026-06-16T12:05:00Z", value: 15}]}
  ].freeze

  test "series: draws one line + its dots per series, flags multi, and has no fill" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", series: SERIES, style: :line, **BASE.merge(points: [])).call

    assert_includes html, "data-metrics-chart-multi-value"
    assert_equal 2, html.scan('data-metrics-chart-target="line"').size, "one line per series"
    assert_includes html, 'data-series-index="0"'
    assert_includes html, 'data-series-index="1"'
    assert_includes html, 'stroke="var(--voodu-purple)"'
    assert_includes html, 'stroke="var(--voodu-blue)"'
    assert_includes html, 'data-metrics-chart-target="dot"', "per-series dots"
    assert_not_includes html, 'data-metrics-chart-target="area"', "line style = no fill"
  end

  # Area multi = the Line multi (one raio stroke + dots per series) PLUS a
  # translucent fill per series, so up to 5 overlapping areas stay readable.
  test "series with :area style draws a translucent fill + a stroke per series" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", series: SERIES, style: :area, **BASE.merge(points: [])).call

    assert_equal 2, html.scan('data-metrics-chart-target="area"').size, "one fill per series"
    assert_equal 2, html.scan('data-metrics-chart-target="line"').size, "one stroke per series"
    assert_includes html, 'fill-opacity="0.14"', "fills are translucent for overlap"
    assert_includes html, 'fill="var(--voodu-purple)"', "fill uses the series color"
    assert_includes html, 'data-metrics-chart-target="dot"', "keeps per-series dots"
  end

  test "a single-series chart carries no multi flag" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", **BASE.merge(points: POINTS)).call

    assert_not_includes html, "data-metrics-chart-multi-value"
  end

  # The multi-series legend is INTERACTIVE: each entry is a button wired to the
  # controller (hover→spotlight, click→toggle) and lives inside the chart's own
  # controller scope so it can reach the lines by series_index.
  test "multi-series renders one interactive legend button per series" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", series: SERIES, **BASE.merge(points: [])).call

    assert_equal 2, html.scan('data-metrics-chart-target="legendItem"').size, "one legend button per series"
    assert_includes html, "mouseenter->metrics-chart#highlightSeries", "hover spotlights"
    assert_includes html, "mouseleave->metrics-chart#unhighlightSeries", "leave restores"
    assert_includes html, "click->metrics-chart#toggleSeries", "click toggles visibility"
    assert_includes html, "<button", "legend entries are buttons (keyboard + a11y)"
  end

  # A stable key is emitted so the controller can persist which lines the
  # operator hid ACROSS a realtime stream refresh (which replaces the chart DOM).
  test "multi-series emits its stable key when given" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", series: SERIES, key: "panel-3", **BASE.merge(points: [])).call

    assert_includes html, 'data-metrics-chart-key-value="panel-3"'
  end

  test "multi-series omits the key value when none is given" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", series: SERIES, **BASE.merge(points: [])).call

    assert_not_includes html, "data-metrics-chart-key-value"
  end

  # Each multi dot carries its series_index so the controller can dim/hide a
  # series' dots in lockstep with its line on legend hover/toggle.
  test "multi-series dots carry their series_index" do
    html = Components::Metrics::Chart.new(color: "var(--voodu-green)", series: SERIES, **BASE.merge(points: [])).call

    dots = html.scan(/<circle[^>]*data-metrics-chart-target="dot"[^>]*>/)

    assert dots.any? { |d| d.include?('data-series-index="0"') }, "series 0 dots tagged"
    assert dots.any? { |d| d.include?('data-series-index="1"') }, "series 1 dots tagged"
  end
end
