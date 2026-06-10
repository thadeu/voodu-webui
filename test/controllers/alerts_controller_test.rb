# frozen_string_literal: true

require "test_helper"

# Exercises the full request stack — also smoke-renders the Phlex
# Index/Frame views and the alerts components (a render error
# surfaces as a 500 here).
class AlertsControllerTest < ActionDispatch::IntegrationTest
  fixtures :islands

  setup do
    @island = islands(:alpha)
    @key    = @island.key
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"
  end

  teardown { ENV["WAREHOUSE"] = @prev_wh }

  test "index renders the empty state when no rules exist" do
    get alerts_path(tenant_key: @key)

    assert_response :success
    assert_includes response.body, "No alert rules yet"
    assert_includes response.body, "Create default rules"
  end

  test "default tab is active and renders firing cards" do
    rule = create_rule(firing: true)
    rule.alert_events.create!(
      island: @island, state: "firing", started_at: 5.minutes.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label, peak_value: 97.2, last_value: 95.0
    )

    get alerts_path(tenant_key: @key)

    assert_response :success
    assert_includes response.body, "Active"
    assert_includes response.body, rule.name
    assert_includes response.body, "alerts-badge-pill-#{@island.id}"
  end

  test "rules tab renders the rules table" do
    rule = create_rule
    rule.update_columns(last_status: "ok")

    get alerts_path(tenant_key: @key, tab: "rules")

    assert_response :success
    assert_includes response.body, rule.name
    assert_includes response.body, "OK"
  end

  test "rules tab shows NO DATA for a never-evaluated rule" do
    create_rule

    get alerts_path(tenant_key: @key, tab: "rules")

    assert_response :success
    assert_includes response.body, "NO DATA"
  end

  test "rules tab links each rule to its metrics scope" do
    create_rule

    get alerts_path(tenant_key: @key, tab: "rules")

    assert_response :success
    assert_includes response.body, metrics_path(tenant_key: @key, scope_kind: "host")
  end

  test "firing card links to the deployment's metrics chart" do
    rule = @island.alert_rules.create!(
      name: "ctrl cpu", metric_kind: "cpu", target_kind: "pod",
      target_scope: "fsw", target_name: "controller",
      comparator: "gte", threshold: 50, duration_seconds: 300,
      firing: true, firing_since: 5.minutes.ago
    )
    @island.pods.create!(
      scope: "fsw", resource_name: "controller", container_name: "fsw-controller.e1e1",
      kind: "deployment", replica_id: "e1e1", payload: "{}", synced_at: Time.current
    )
    rule.alert_events.create!(
      island: @island, state: "firing", started_at: 5.minutes.ago,
      threshold: 50, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label, peak_value: 80, last_value: 75
    )

    get alerts_path(tenant_key: @key)

    assert_response :success
    assert_includes response.body, "Open metrics"
    assert_includes response.body, metrics_path(tenant_key: @key, scope_kind: "pod", scope_id: "fsw-controller.e1e1")
  end

  test "history tab renders the timeline and the date filter" do
    rule = create_rule
    rule.alert_events.create!(
      island: @island, state: "resolved",
      started_at: 2.hours.ago, resolved_at: 1.hour.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label, peak_value: 93.0, last_value: 80.0
    )

    get alerts_path(tenant_key: @key, tab: "history")

    assert_response :success
    assert_includes response.body, "Timeline"
    assert_includes response.body, "Today"
    assert_includes response.body, "resolved"
    assert_includes response.body, "time-range-filter"
  end

  test "history range param narrows the window" do
    rule = create_rule
    rule.alert_events.create!(
      island: @island, state: "resolved",
      started_at: 3.days.ago, resolved_at: 3.days.ago + 60,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label, peak_value: 93.0, last_value: 80.0
    )

    get alerts_path(tenant_key: @key, tab: "history", range: "24h")
    assert_response :success
    assert_includes response.body, "No resolved alerts in this range"

    get alerts_path(tenant_key: @key, tab: "history", range: "7d")
    assert_response :success
    assert_not_includes response.body, "No resolved alerts in this range"
  end

  test "history custom range honors from and until" do
    rule = create_rule
    rule.alert_events.create!(
      island: @island, state: "resolved",
      started_at: 5.days.ago, resolved_at: 5.days.ago + 60,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label, peak_value: 93.0, last_value: 80.0
    )

    get alerts_path(
      tenant_key: @key, tab: "history", range: "custom",
      from: 6.days.ago.utc.iso8601, until: 4.days.ago.utc.iso8601
    )

    assert_response :success
    assert_not_includes response.body, "No resolved alerts in this range"
  end

  test "an unknown tab falls back to active" do
    create_rule(firing: true)

    get alerts_path(tenant_key: @key, tab: "bogus")

    assert_response :success
    assert_includes response.body, "aria-current=\"page\""
  end

  test "all clear strip shows on the active tab when nothing fires" do
    create_rule

    get alerts_path(tenant_key: @key)

    assert_response :success
    assert_includes response.body, "All clear"
  end

  test "Turbo-Frame request returns only the frame body" do
    create_rule

    get alerts_path(tenant_key: @key), headers: { "Turbo-Frame" => "alerts-live" }

    assert_response :success
    assert_includes response.body, "alerts-live"
    assert_not_includes response.body, "<aside"
  end

  private

  def create_rule(firing: false)
    @island.alert_rules.create!(
      name: "Host CPU ≥ 90%", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300,
      firing: firing, firing_since: firing ? 5.minutes.ago : nil
    )
  end
end
