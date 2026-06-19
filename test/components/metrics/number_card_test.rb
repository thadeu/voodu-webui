# frozen_string_literal: true

require "test_helper"

class Components::Metrics::NumberCardTest < ActiveSupport::TestCase
  def render_card(**opts)
    base = {label: "fs · INVITE", color: "var(--voodu-orange)", formatted: "1,284", range: "1h"}

    Components::Metrics::NumberCard.new(**base.merge(opts)).call
  end

  test "renders the formatted count, the label and the range chip" do
    html = render_card

    assert_includes html, "1,284"
    assert_includes html, "fs · INVITE"
    assert_includes html, "1h"
  end

  test "carries the panel key + display target so the grid can hide/reorder it" do
    html = render_card(metric: "k0")

    assert_includes html, 'data-metric-key="k0"'
    assert_includes html, 'data-metrics-display-target="card"'
  end

  test "without a panel key it opts out of the display-filter system (no resize handles)" do
    html = render_card(metric: nil)

    assert_not_includes html, "data-metric-key"
    assert_not_includes html, "startResize"
  end

  test "prefixes the count with ≥ when truncated" do
    assert_includes render_card(truncated: true), "≥"
    assert_not_includes render_card(truncated: false), "≥"
  end

  test "shows the retention note only when clamped" do
    assert_includes render_card(clamped: true), "retention"
    assert_not_includes render_card(clamped: false), "retention"
  end

  test "default_visible false emits the data flag for the first-run hide heuristic" do
    assert_includes render_card(metric: "k0", default_visible: false), 'data-default-visible="false"'
    assert_not_includes render_card(metric: "k0", default_visible: true), "data-default-visible"
  end

  test "renders a sparkline svg when given a series of >=2 points" do
    series = [
      {ts: "2026-06-19T14:45:00Z", value: 3.0, formatted: "3"},
      {ts: "2026-06-19T14:46:00Z", value: 5.0, formatted: "5"}
    ]

    assert_includes render_card(series: series, range_ms: 3_600_000), "<svg"
  end

  test "omits the sparkline when there is no history (live-scan fallback)" do
    assert_not_includes render_card(series: []), "<svg"
  end

  test "renders the agg sub-line when given, omits it for a plain count" do
    assert_includes render_card(sub: "avg-marker"), "avg-marker"
    assert_not_includes render_card(sub: nil), "avg-marker"
  end
end
