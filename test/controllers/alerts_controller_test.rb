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

  test "index renders firing cards, rules table and history" do
    rule = create_rule(firing: true)
    rule.alert_events.create!(
      island: @island, state: "firing", started_at: 5.minutes.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label, peak_value: 97.2, last_value: 95.0
    )
    rule.alert_events.create!(
      island: @island, state: "resolved",
      started_at: 2.hours.ago, resolved_at: 1.hour.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label, peak_value: 93.0, last_value: 80.0
    )

    get alerts_path(tenant_key: @key)

    assert_response :success
    assert_includes response.body, "FIRING"
    assert_includes response.body, rule.name
    assert_includes response.body, "alerts-badge-pill-#{@island.id}"
    assert_includes response.body, "resolved"
  end

  test "all clear strip shows when rules exist but nothing fires" do
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
