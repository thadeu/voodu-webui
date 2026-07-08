# frozen_string_literal: true

require "test_helper"

# The maximize modal for a MULTI-series (multi-pod) panel: it renders the big
# multi chart + interactive legend, with only the time controls — the single-
# scope pickers (metric / pod) and the min/avg/max strip don't apply to a fixed
# N-pod panel.
class Views::Metrics::ChartModalBodyTest < ActiveSupport::TestCase
  setup do
    controller = ApplicationController.new
    req = ActionDispatch::TestRequest.create
    req.path_parameters = {org_id: "abcd1234", server_key: "ABC123", controller: "metrics", action: "chart"}
    controller.request = req
    controller.response = ActionDispatch::TestResponse.new
    @view = controller.view_context
  end

  POINTS = [
    {ts: "2026-06-16T12:00:00Z", value: 10},
    {ts: "2026-06-16T12:05:00Z", value: 20}
  ].freeze

  def multi_chart(chart_type: "line")
    {
      multi: true, chart_type: chart_type, label: "3 pods CPU", unit: "%", panel_key: "k3",
      series: [
        {label: "api", color: "var(--voodu-blue)", points: POINTS, current: 20},
        {label: "web", color: "var(--voodu-purple)", points: POINTS, current: 15}
      ]
    }
  end

  def render_multi(chart_type: "line")
    Views::Metrics::ChartModalBody.new(
      chart: multi_chart(chart_type: chart_type), range: "1h", range_ms: 3_600_000,
      query: {pid: "abc", panel: "3", range: "1h"}
    ).render_in(@view)
  end

  test "a multi Line panel renders the multi chart + interactive legend, keyed by the panel" do
    html = render_multi

    assert_includes html, "data-metrics-chart-multi-value", "renders the multi chart"
    assert_equal 2, html.scan('data-metrics-chart-target="line"').size, "one line per series"
    assert_includes html, 'data-metrics-chart-target="legendItem"', "the interactive legend"
    assert_includes html, 'data-metrics-chart-key-value="k3"', "keyed so it shares grid state"
  end

  test "a multi Area panel carries its fills into the modal" do
    html = render_multi(chart_type: "area")

    assert_includes html, 'data-metrics-chart-target="area"', "area fills render in the modal"
  end

  # The realtime refresh + range pills must stay scoped to THIS panel (pid+panel)
  # so a tick / range switch re-fetches the multi chart, not a default single one.
  test "the modal's refresh url keeps the panel reference" do
    html = render_multi

    assert_match(/data-refresh-url="[^"]*panel=3[^"]*pid=abc/, html)
  end
end
