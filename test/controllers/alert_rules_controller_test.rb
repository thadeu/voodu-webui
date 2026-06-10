# frozen_string_literal: true

require "test_helper"

class AlertRulesControllerTest < ActionDispatch::IntegrationTest
  fixtures :islands

  setup do
    @island = islands(:alpha)
    @key    = @island.key
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"
  end

  teardown { ENV["WAREHOUSE"] = @prev_wh }

  test "new renders the modal form" do
    get new_alert_rule_path(tenant_key: @key)

    assert_response :success
    assert_includes response.body, "New alert rule"
  end

  test "create decodes a pod target and redirects" do
    assert_difference("AlertRule.count", 1) do
      post alert_rules_path(tenant_key: @key), params: {
        alert_rule: {
          name: "web reqs", metric_kind: "req_s", target: "pod|clowk|web",
          comparator: "gte", threshold: "50", duration_seconds: "120"
        }
      }
    end

    rule = AlertRule.order(:id).last
    assert_equal "pod",   rule.target_kind
    assert_equal "clowk", rule.target_scope
    assert_equal "web",   rule.target_name
    assert_equal 50.0,    rule.threshold
    assert_redirected_to alerts_path(tenant_key: @key)
  end

  test "create with host target nils the pod columns" do
    post alert_rules_path(tenant_key: @key), params: {
      alert_rule: {
        name: "host cpu", metric_kind: "cpu", target: "host",
        comparator: "gte", threshold: "90", duration_seconds: "300"
      }
    }

    rule = AlertRule.order(:id).last
    assert_equal "host", rule.target_kind
    assert_nil rule.target_scope
    assert_nil rule.target_name
  end

  test "invalid create re-renders the form with the model error" do
    post alert_rules_path(tenant_key: @key), params: {
      alert_rule: {
        name: "bad", metric_kind: "disk", target: "pod|a|b",
        comparator: "gte", threshold: "85", duration_seconds: "300"
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "disk usage is only sampled"
  end

  test "update edits in place" do
    rule = create_rule

    patch alert_rule_path(tenant_key: @key, id: rule.id), params: {
      alert_rule: {
        name: rule.name, metric_kind: "cpu", target: "host",
        comparator: "gte", threshold: "95", duration_seconds: "600"
      }
    }

    assert_redirected_to alerts_path(tenant_key: @key)
    rule.reload
    assert_equal 95.0, rule.threshold
    assert_equal 600,  rule.duration_seconds
  end

  test "editing a firing rule's condition closes the stale episode" do
    rule = create_rule(firing: true)
    event = rule.alert_events.create!(
      island: @island, state: "firing", started_at: 5.minutes.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label
    )

    patch alert_rule_path(tenant_key: @key, id: rule.id), params: {
      alert_rule: {
        name: rule.name, metric_kind: "memory", target: "host",
        comparator: "gte", threshold: "90", duration_seconds: "300"
      }
    }

    rule.reload
    assert_not rule.firing, "condition change must drop the stale firing flag"
    assert_equal "resolved", event.reload.state
  end

  test "renaming a firing rule leaves the live episode intact" do
    rule = create_rule(firing: true)
    rule.alert_events.create!(
      island: @island, state: "firing", started_at: 5.minutes.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label
    )

    patch alert_rule_path(tenant_key: @key, id: rule.id), params: {
      alert_rule: {
        name: "Renamed", metric_kind: "cpu", target: "host",
        comparator: "gte", threshold: "90", duration_seconds: "300"
      }
    }

    rule.reload
    assert rule.firing, "a pure rename must not disturb the open episode"
    assert_equal "firing", rule.open_event&.state
  end

  test "toggle pauses a firing rule and resolves its episode" do
    rule = create_rule(firing: true)
    event = rule.alert_events.create!(
      island: @island, state: "firing", started_at: 5.minutes.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label
    )

    post toggle_alert_rule_path(tenant_key: @key, id: rule.id)

    assert_redirected_to alerts_path(tenant_key: @key)
    rule.reload
    assert_not rule.enabled
    assert_not rule.firing
    assert_equal "resolved", event.reload.state
  end

  test "toggle resumes a paused rule" do
    rule = create_rule
    rule.update!(enabled: false)

    post toggle_alert_rule_path(tenant_key: @key, id: rule.id)

    assert rule.reload.enabled
  end

  test "destroy removes the rule and its events" do
    rule = create_rule(firing: true)
    rule.alert_events.create!(
      island: @island, state: "firing", started_at: 5.minutes.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label
    )

    assert_difference("AlertRule.count", -1) do
      delete alert_rule_path(tenant_key: @key, id: rule.id)
    end

    assert_equal 0, AlertEvent.where(island_id: @island.id).count
    assert_redirected_to alerts_path(tenant_key: @key)
  end

  test "defaults seeds the starter pack idempotently" do
    assert_difference("AlertRule.count", 3) do
      post defaults_alert_rules_path(tenant_key: @key)
    end

    assert_no_difference("AlertRule.count") do
      post defaults_alert_rules_path(tenant_key: @key)
    end
  end

  test "one island cannot address another island's rule" do
    rule = create_rule
    other_key = islands(:beta).key

    post toggle_alert_rule_path(tenant_key: other_key, id: rule.id)

    assert_redirected_to alerts_path(tenant_key: other_key)
    assert rule.reload.enabled, "cross-tenant toggle must not touch the rule"
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
