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
end
