# frozen_string_literal: true

require "test_helper"

# Exercises the full request stack — these also smoke-render the Phlex
# List/Form/Index views (a render error surfaces as a 500 here).
# Warehouse mode keeps /metrics rendering off the network.
class MetricDashboardsControllerTest < ActionDispatch::IntegrationTest
  fixtures :islands

  setup do
    @island = islands(:alpha)
    @key = @island.key
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"
  end

  teardown { ENV["WAREHOUSE"] = @prev_wh }

  HOST = {
    "scope_kind" => "host", "metric" => "cpu_percent", "scale" => "percent",
    "label" => "CPU", "color" => "var(--voodu-accent)", "unit" => "%"
  }.freeze

  test "create persists panels and reopens the manager on the new dashboard" do
    assert_difference("MetricDashboard.count", 1) do
      post metric_dashboards_path(tenant_key: @key),
        params: {metric_dashboard: {name: "overview", panels: [HOST].to_json}}
    end

    d = MetricDashboard.order(:id).last
    assert_equal "overview", d.name
    assert_equal 1, d.panels.size
    assert_equal "cpu_percent", d.panels.first["metric"]
    # Don't auto-close: land back in the manager on the new dashboard.
    assert_redirected_to metric_dashboards_path(tenant_key: @key, edit: d.to_param)
  end

  test "create with a blank name re-renders 422" do
    post metric_dashboards_path(tenant_key: @key),
      params: {metric_dashboard: {name: "", panels: [HOST].to_json}}

    assert_response :unprocessable_entity
  end

  test "index renders the manage modal with the dashboard rail + editor frame" do
    @island.metric_dashboards.create!(name: "saved-one", panels: [HOST])

    get metric_dashboards_path(tenant_key: @key)

    assert_response :success
    assert_match "Dashboards", @response.body            # modal title
    assert_match "saved-one", @response.body             # rail item
    assert_match "New dashboard", @response.body         # rail new button
    assert_match "dashboard-editor", @response.body      # lazy editor turbo-frame
  end

  test "new renders the builder (embed)" do
    get new_metric_dashboard_path(tenant_key: @key, embed: 1)

    assert_response :success
    assert_match "Add panel", @response.body
    assert_match "dashboard-builder", @response.body
  end

  test "edit renders the builder prefilled (embed)" do
    d = @island.metric_dashboards.create!(name: "editme", panels: [HOST])

    get edit_metric_dashboard_path(tenant_key: @key, id: d.to_param, embed: 1)

    assert_response :success
    assert_match "editme", @response.body
  end

  test "pin makes /metrics open to the dashboard" do
    d = @island.metric_dashboards.create!(name: "pinme", panels: [HOST])

    post pin_metric_dashboard_path(tenant_key: @key, id: d.to_param)
    assert d.reload.pinned
    assert_redirected_to metrics_path(tenant_key: @key, pid: d.to_param)

    get metrics_path(tenant_key: @key)
    assert_response :success
    assert_match "pinme", @response.body
  end

  test "a pinned dashboard sets the default but does not lock out the host view" do
    @island.metric_dashboards.create!(name: "pinned-one", panels: [HOST], pinned: true)

    # bare /metrics opens the pinned dashboard (the default)
    get metrics_path(tenant_key: @key)
    assert_response :success
    assert_match "pinned-one", @response.body

    # …but ?scope_kind=host forces the host view despite the pin
    get metrics_path(tenant_key: @key, scope_kind: "host")
    assert_response :success
    assert_match "Host (default)", @response.body
  end

  test "an explicit ?dashboard= overrides a different pinned dashboard" do
    @island.metric_dashboards.create!(name: "the-pinned", panels: [HOST], pinned: true)
    other = @island.metric_dashboards.create!(name: "the-other", panels: [HOST])

    get metrics_path(tenant_key: @key, pid: other.to_param)
    assert_response :success
    assert_match "the-other", @response.body
  end

  test "unpin reverts /metrics to the host view" do
    d = @island.metric_dashboards.create!(name: "p", panels: [HOST], pinned: true)

    post unpin_metric_dashboard_path(tenant_key: @key, id: d.to_param)
    assert_not d.reload.pinned
    assert_redirected_to metrics_path(tenant_key: @key)
  end

  test "destroy removes the dashboard and redirects" do
    d = @island.metric_dashboards.create!(name: "gone", panels: [HOST])

    assert_difference("MetricDashboard.count", -1) do
      delete metric_dashboard_path(tenant_key: @key, id: d.to_param)
    end
    assert_redirected_to metrics_path(tenant_key: @key)
  end

  test "display_settings in dashboard mode lists the active dashboard's panels" do
    d = @island.metric_dashboards.create!(
      name: "ds",
      panels: [HOST, HOST.merge("label" => "host · CPU again")]
    )

    get metrics_display_settings_path(tenant_key: @key, pid: d.to_param, kind: "dashboard:#{d.id}")

    assert_response :success
    # one settings card per panel, keyed by panel_card_key (k0, k1),
    # namespaced to this dashboard.
    assert_match "dashboard:#{d.id}", @response.body
    assert_match 'data-metric="k0"', @response.body
    assert_match 'data-metric="k1"', @response.body
  end

  test "metrics renders the dashboard panel grid in dashboard mode" do
    d = @island.metric_dashboards.create!(name: "grid", panels: [HOST])

    get metrics_path(tenant_key: @key, pid: d.to_param)

    assert_response :success
    assert_match "metrics-charts", @response.body
    assert_match "grid", @response.body
  end

  test "metrics stacks multiple dashboards in selection order for ?pid=a,b" do
    cpu = @island.metric_dashboards.create!(name: "cpu-dash", panels: [HOST])
    mem = @island.metric_dashboards.create!(name: "mem-dash", panels: [HOST])

    get metrics_path(tenant_key: @key, pid: "#{cpu.to_param},#{mem.to_param}")

    assert_response :success
    # both section headers render…
    assert_match "cpu-dash", @response.body
    assert_match "mem-dash", @response.body
    # …in selection order (cpu before mem).
    assert_operator @response.body.index("cpu-dash"), :<, @response.body.index("mem-dash")
    # multi trigger label reflects the count.
    assert_match "2 dashboards", @response.body
  end

  test "update reopens the manager on the saved dashboard (does not auto-close)" do
    d = @island.metric_dashboards.create!(name: "dash-b", panels: [HOST])

    patch metric_dashboard_path(tenant_key: @key, id: d.to_param),
      params: {metric_dashboard: {name: "dash-b2", panels: [HOST].to_json}}

    assert_equal "dash-b2", d.reload.name
    assert_redirected_to metric_dashboards_path(tenant_key: @key, edit: d.to_param)
  end

  test "update stays in the manager regardless of any return_to" do
    d = @island.metric_dashboards.create!(name: "dash-x", panels: [HOST])

    patch metric_dashboard_path(tenant_key: @key, id: d.to_param),
      params: {return_to: metrics_path(tenant_key: @key, pid: d.to_param),
               metric_dashboard: {name: "dash-x", panels: [HOST].to_json}}

    assert_redirected_to metric_dashboards_path(tenant_key: @key, edit: d.to_param)
  end

  test "multi ?pid silently drops unknown uuids and renders the rest" do
    only = @island.metric_dashboards.create!(name: "real-dash", panels: [HOST])

    get metrics_path(tenant_key: @key, pid: "#{only.to_param},does-not-exist")

    assert_response :success
    assert_match "real-dash", @response.body
  end
end
