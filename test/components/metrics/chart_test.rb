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
end
