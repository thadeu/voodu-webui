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

  test "number-only tile (no chart) scales the count up to fill the card" do
    html = render_card(series: [], formatted: "5")

    assert_includes html, "text-[72px]", "short count goes large when there's no chart"
  end

  test "a tile WITH a chart keeps the count modest (chart needs the room)" do
    series = [
      {ts: "2026-06-19T14:45:00Z", value: 3.0, formatted: "3"},
      {ts: "2026-06-19T14:46:00Z", value: 5.0, formatted: "5"}
    ]
    html = render_card(series: series, range_ms: 3_600_000, formatted: "5")

    assert_includes html, "text-[40px]", "with a chart the number stays modest"
    assert_not_includes html, "text-[72px]"
  end

  test "a long count steps the number-only size down so it doesn't overflow" do
    assert_includes render_card(series: [], formatted: "1,284,902"), "text-[40px]"
    assert_includes render_card(series: [], formatted: "12,345"), "text-[52px]"
  end

  test "renders the agg sub-line when given, omits it for a plain count" do
    assert_includes render_card(sub: "avg-marker"), "avg-marker"
    assert_not_includes render_card(sub: nil), "avg-marker"
  end

  # ── Show-timeline options popover (mirrors the Line chart's "Show dots") ──────
  SPARK = [
    {ts: "2026-06-19T14:45:00Z", value: 3.0, formatted: "3"},
    {ts: "2026-06-19T14:46:00Z", value: 5.0, formatted: "5"}
  ].freeze

  test "with a sparkline + a key, renders the Show-timeline popover wired for live toggle" do
    html = render_card(series: SPARK, range_ms: 3_600_000, metric: "k0")

    assert_includes html, "Show timeline", "the popover's toggle label"
    assert_includes html, 'data-panel-options-target="timeline"', "the switch broadcasts a timeline change"
    assert_includes html, 'data-number-card-target="timeline"', "the sparkline is the toggle target"
    assert_includes html, "number-card", "the card controller shows/hides the sparkline live"
  end

  test "a bare number tile (no series) has no options popover — nothing to toggle" do
    html = render_card(series: [], metric: "k0")

    assert_not_includes html, "Show timeline"
    assert_not_includes html, 'data-panel-options-target="timeline"'
    assert_not_includes html, "number-card"
  end

  test "no options popover without a panel key (no key to broadcast on)" do
    html = render_card(series: SPARK, range_ms: 3_600_000, metric: nil)

    assert_not_includes html, "Show timeline"
  end
end
