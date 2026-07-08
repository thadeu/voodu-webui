# frozen_string_literal: true

require "test_helper"

class Components::Metrics::ChartCardTest < ActiveSupport::TestCase
  POINTS = [
    {ts: "2026-06-16T12:00:00Z", value: 10},
    {ts: "2026-06-16T12:05:00Z", value: 20}
  ].freeze

  def card(chart_type:, **over)
    Components::Metrics::ChartCard.new(
      label: "CPU", color: "var(--voodu-purple)", unit: "%",
      points: POINTS, range_ms: 900_000, chart_type: chart_type, metric: "k1", **over
    ).call
  end

  # The per-panel options menu (⋮) is a Line-chart-only affordance for now, with
  # a single "Show dots" toggle. It sits beside the maximize button and keys its
  # pref (persisted client-side) to the panel id.
  test "a line panel renders the triple-dot options menu with a Show dots toggle" do
    html = card(chart_type: "line")

    assert_includes html, "popover#toggle", "renders the ⋮ trigger"
    assert_includes html, 'data-controller="panel-options"', "menu carries its controller"
    assert_includes html, 'data-panel-options-key-value="k1"', "keyed by the panel id"
    assert_includes html, "change->panel-options#toggleDots", "the toggle is wired"
    assert_includes html, "Show dots"
  end

  test "area / bar / gauge panels render NO options menu (Line-only for now)" do
    %w[area bars gauge_radial gauge_linear].each do |ct|
      html = card(chart_type: ct, capacity_pct: 50) # capacity_pct gives gauges a ceiling

      assert_not_includes html, "panel-options", "#{ct} must not render the options menu"
    end
  end

  # Multi-series Line also gets the menu — the dots toggle applies to every line.
  test "a multi-series line panel renders the options menu" do
    series = [{label: "a", color: "var(--voodu-purple)", points: POINTS}]
    html = Components::Metrics::ChartCard.new(
      label: "Pods", color: "var(--voodu-purple)", unit: "%",
      points: [], series: series, range_ms: 900_000, chart_type: "line", metric: "k7"
    ).call

    assert_includes html, 'data-controller="panel-options"'
    assert_includes html, 'data-panel-options-key-value="k7"'
  end
end
