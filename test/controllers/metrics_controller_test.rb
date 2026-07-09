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

  # ── Builder panel preview (POST /metrics/previews/panel) ────────────────────

  def preview(panel)
    post metrics_preview_panel_path(server_key: @key), params: {panel: panel.to_json}
  end

  test "preview renders an in-progress metric panel as its card" do
    preview({scope_kind: "host", metric: "cpu_percent", scale: "percent", chart_type: "area",
             label: "CPU preview", color: "var(--voodu-accent)", unit: "%", server_id: @server.id})

    assert_response :success
    assert_match "CPU preview", @response.body, "the panel renders as a card (not a 500)"
  end

  test "preview of a malformed / empty panel returns the placeholder, not a 500" do
    preview({})

    assert_response :success
    assert_match(/to preview/i, @response.body, "empty panel → placeholder")
  end

  # An http Table panel fetches its rows client-side, and the endpoint re-resolves
  # the panel's request config (url + auth headers) SERVER-SIDE. A preview panel
  # isn't persisted, so the card gets a one-shot "preview-<token>" dashboard id
  # (config cached server-side); the url NEVER reaches the client.
  test "preview of an http Table panel hands the card a preview token, not the url" do
    preview({source: "http", scope_kind: "table", chart_type: "table", view: "response",
             label: "External API", color: "var(--voodu-cyan)", server_id: @server.id,
             url: "https://api.example.test/posts", method: "GET",
             mapping: {root: "", columns: [{field: "id"}, {field: "title"}]}})

    assert_response :success
    assert_match(/data-data-table-dashboard-value="preview-[a-f0-9]+"/, @response.body,
      "the card resolves its rows via a one-shot, server-side preview token")
    assert_no_match(/api\.example\.test/, @response.body,
      "the request url never reaches the client — only the opaque token does")
  end

  test "preview never renders a panel pointing at ANOTHER org's server (isolation)" do
    gamma = servers(:gamma)
    assert_not_equal @org.id, gamma.org_id

    preview({scope_kind: "host", metric: "cpu_percent", scale: "percent", chart_type: "area",
             label: "forged", color: "c", unit: "%", server_id: gamma.id})

    assert_response :success
    # cross-org server_id fails panels_well_formed → the placeholder, and the
    # read path never runs (no cross-org read at all).
    assert_no_match "forged", @response.body, "the cross-org panel is NOT rendered"
    assert_match(/to preview/i, @response.body, "→ placeholder")
  end

  # A HEP3 group-by panel (`… | count() by to_user`) renders end-to-end without a
  # 500 — the full path: chart_for → hep_grouped_chart_for → the grid → GroupCard.
  test "a hep3 group-by Table panel renders the dashboard without error" do
    HepMessage.bulk_insert([
      {server_id: @server.id, scope: "fsw", name: "hep3-api",
       payload: {ts: (Time.current - 60).utc.strftime("%Y-%m-%d %H:%M:%S.000000"),
                 call_id: "c1", x_cid: "c1", to_user: "5512", method: "INVITE", response_code: 0}.to_json}
    ])
    @org.metric_dashboards.destroy_all
    @org.metric_dashboards.create!(
      name: "by-number", pinned: true,
      panels: [{"scope_kind" => "table", "source" => "hep3", "chart_type" => "table",
                "scope" => "fsw", "name" => "hep3-api", "view" => "messages", "server_id" => @server.id,
                "label" => "Calls by number", "color" => "var(--voodu-orange)",
                "filter_query" => "| count() by to_user"}]
    )

    get metrics_path(server_key: @key, range: "1h")

    assert_response :success
    assert_match "Calls by number", @response.body, "the grouped panel renders (GroupCard), not a 500"
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
