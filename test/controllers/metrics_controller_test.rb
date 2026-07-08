# frozen_string_literal: true

require "test_helper"

# Exercises the /metrics custom date-range wiring end-to-end (controller
# resolves the window → data object goes custom → view swaps the realtime
# pulse for a "fixed window" badge). Warehouse mode keeps the page render
# off the network; a pinned dashboard gives the page something to draw.
class MetricsControllerTest < ActionDispatch::IntegrationTest
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @org = @server.org
    @key = @server.key
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"
    # Dashboards live at the org (M2); the host panel carries its server_id.
    @org.metric_dashboards.create!(
      name: "pinned-one", pinned: true,
      panels: [{"scope_kind" => "host", "metric" => "cpu_percent", "scale" => "percent",
                "label" => "CPU", "color" => "var(--voodu-accent)", "unit" => "%", "server_id" => @server.id}]
    )
  end

  teardown { ENV["WAREHOUSE"] = @prev_wh }

  test "a relative range renders the realtime indicator, not a fixed window" do
    get metrics_path(server_key: @key, range: "1h")

    assert_response :success
    assert_match "realtime", @response.body
    assert_no_match(/fixed window/, @response.body)
    assert_match "last ", @response.body
  end

  test "range=custom with a valid window renders the fixed-window badge + custom chip" do
    get metrics_path(server_key: @key, range: "custom",
      from: "2026-06-19T09:00:00Z", until: "2026-06-19T10:00:00Z")

    assert_response :success
    assert_match "fixed window", @response.body
    assert_no_match(/realtime/, @response.body)
    assert_match 'name="range" value="custom"', @response.body
  end

  test "range=custom with only one bound falls back to the relative range" do
    get metrics_path(server_key: @key, range: "custom", from: "2026-06-19T09:00:00Z")

    assert_response :success
    assert_match "realtime", @response.body, "half window → relative fallback, still live"
    assert_no_match(/fixed window/, @response.body)
  end

  test "range=custom with until earlier than from falls back to relative" do
    get metrics_path(server_key: @key, range: "custom",
      from: "2026-06-19T10:00:00Z", until: "2026-06-19T09:00:00Z")

    assert_response :success
    assert_match "realtime", @response.body, "inverted window → relative fallback"
    assert_no_match(/fixed window/, @response.body)
  end

  # The maximize button must open the modal on the SAME window the operator is
  # viewing — including a brushed custom window. Assert it on the FRAME
  # (poll/broadcast) re-render, which is the path that used to drift: after the
  # first tick the frame swapped in an expand URL missing from/until, so the
  # maximized chart snapped back to the default range.
  test "the maximize link carries the active custom window on the frame re-render" do
    get metrics_path(server_key: @key, range: "custom",
      from: "2026-06-19T09:00:00Z", until: "2026-06-19T10:00:00Z"),
      headers: {"Turbo-Frame" => "metrics-charts"}

    assert_response :success
    assert_match %r{/metrics/chart\?[^"']*range=custom}, @response.body,
      "expand URL must pin range=custom"
    assert_match(/from=2026-06-19/, @response.body, "expand URL must carry the window's from")
    assert_match(/until=2026-06-19/, @response.body, "expand URL must carry the window's until")
  end

  # A "zeroed" panel — a render the measure can't fill (a host metric asked to be
  # a Table) — must render the dashboard EMPTY, never a 500. Exercises the full
  # path: chart_for → zeroed_card → the grid → an empty-points ChartCard.
  test "a zeroed panel (metric + table) renders the dashboard without error" do
    @org.metric_dashboards.destroy_all
    @org.metric_dashboards.create!(
      name: "zeroed", pinned: true,
      panels: [{"scope_kind" => "host", "metric" => "mem_used_bytes", "scale" => "bytes_to_gb",
                "label" => "Mem as Table", "color" => "var(--voodu-blue)", "unit" => "GB",
                "chart_type" => "table", "server_id" => @server.id}]
    )

    get metrics_path(server_key: @key, range: "1h")

    assert_response :success
    assert_match "Mem as Table", @response.body, "the zeroed panel still renders (empty), not a 500"
  end

  # A log-query panel rendered as a chart maximizes like the others: the
  # /metrics/chart endpoint's source=log branch rebuilds the count chart for the
  # modal (a synthetic one-panel dashboard → log_chart_for), not a 404.
  test "the chart endpoint rebuilds a log-query count chart for maximize" do
    get metrics_chart_path(server_key: @key, source: "log", scope: "fs", name: "fs",
      query: "@message like /INVITE/", chart_type: "area",
      label: "calls", color: "var(--voodu-orange)", server_id: @server.id, range: "1h"),
      headers: {"Accept" => "text/vnd.turbo-stream.html"}

    assert_response :success
    assert_match "chart-modal-body", @response.body, "modal body streamed (not a 404)"
    assert_match "calls", @response.body, "the panel label rides into the modal title"
  end
end
