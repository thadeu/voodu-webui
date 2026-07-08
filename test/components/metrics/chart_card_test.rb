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
    # Polished UI: a header naming the panel, the reusable macOS-style switch
    # (hidden peer checkbox), and a keyboard hint ("D" for dots).
    assert_includes html, "peer sr-only", "checkbox is a hidden peer (switch, not raw checkbox)"
    assert_includes html, "peer-checked:bg-voodu-accent", "the switch track lights up when on"
    assert_match(/uppercase[^"]*">\s*CPU/m, html, "header names the panel")
    assert_match(/font-voodu-mono[^"]*">\s*D\s*</m, html, "shows the 'D' (dots) keyboard hint")
  end

  # No dots → no menu: single Area (no per-point dots), Bar, and gauges.
  test "single-area / bar / gauge panels render NO options menu (no dots to toggle)" do
    %w[area bars gauge_radial gauge_linear].each do |ct|
      html = card(chart_type: ct, capacity_pct: 50) # capacity_pct gives gauges a ceiling

      assert_not_includes html, "panel-options", "#{ct} must not render the options menu"
    end
  end

  def multi_card(chart_type:)
    series = [{label: "a", color: "var(--voodu-purple)", points: POINTS}]

    Components::Metrics::ChartCard.new(
      label: "Pods", color: "var(--voodu-purple)", unit: "%",
      points: [], series: series, range_ms: 900_000, chart_type: chart_type, metric: "k7"
    ).call
  end

  # Both multi-series shapes that draw dots get the menu: Line + Area.
  test "multi-series line AND area panels render the options menu" do
    %w[line area].each do |ct|
      html = multi_card(chart_type: ct)

      assert_includes html, 'data-controller="panel-options"', "multi #{ct} renders the menu"
      assert_includes html, 'data-panel-options-key-value="k7"'
    end
  end
end
