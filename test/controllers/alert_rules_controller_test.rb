# frozen_string_literal: true

require "test_helper"

class AlertRulesControllerTest < ActionDispatch::IntegrationTest
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @key = @server.key
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"
  end

  teardown { ENV["WAREHOUSE"] = @prev_wh }

  test "new renders the modal form" do
    get new_alert_rule_path(server_key: @key)

    assert_response :success
    assert_includes response.body, "New alert rule"
  end

  test "create decodes a pod target (with its server) and redirects" do
    assert_difference("AlertRule.count", 1) do
      post alert_rules_path(server_key: @key), params: {
        alert_rule: {
          name: "web reqs", metric_kind: "req_s", target: "pod|#{@server.id}|clowk|web",
          comparator: "gte", threshold: "50", duration_seconds: "120"
        }
      }
    end

    rule = AlertRule.order(:id).last
    assert_equal @server.id, rule.server_id, "the target server rides in the encoded value"
    assert_equal @server.org_id, rule.org_id, "org derived from the target server"
    assert_equal "pod", rule.target_kind
    assert_equal "clowk", rule.target_scope
    assert_equal "web", rule.target_name
    assert_equal 50.0, rule.threshold
    assert_redirected_to alerts_path(server_key: @key)
  end

  test "create with host target nils the pod columns" do
    post alert_rules_path(server_key: @key), params: {
      alert_rule: {
        name: "host cpu", metric_kind: "cpu", target: "host|#{@server.id}",
        comparator: "gte", threshold: "90", duration_seconds: "300"
      }
    }

    rule = AlertRule.order(:id).last
    assert_equal "host", rule.target_kind
    assert_equal @server.id, rule.server_id
    assert_nil rule.target_scope
    assert_nil rule.target_name
  end

  test "invalid create re-renders the form with the model error" do
    post alert_rules_path(server_key: @key), params: {
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

    patch alert_rule_path(server_key: @key, id: rule.id), params: {
      alert_rule: {
        name: rule.name, metric_kind: "cpu", target: "host",
        comparator: "gte", threshold: "95", duration_seconds: "600"
      }
    }

    assert_redirected_to alerts_path(server_key: @key)
    rule.reload
    assert_equal 95.0, rule.threshold
    assert_equal 600, rule.duration_seconds
  end

  test "editing a firing rule's condition closes the stale episode" do
    rule = create_rule(firing: true)
    event = rule.alert_events.create!(
      server: @server, state: "firing", started_at: 5.minutes.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label
    )

    patch alert_rule_path(server_key: @key, id: rule.id), params: {
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
      server: @server, state: "firing", started_at: 5.minutes.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label
    )

    patch alert_rule_path(server_key: @key, id: rule.id), params: {
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
      server: @server, state: "firing", started_at: 5.minutes.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label
    )

    post toggle_alert_rule_path(server_key: @key, id: rule.id)

    assert_redirected_to alerts_path(server_key: @key)
    rule.reload
    assert_not rule.enabled
    assert_not rule.firing
    assert_equal "resolved", event.reload.state
  end

  test "toggle resumes a paused rule" do
    rule = create_rule
    rule.update!(enabled: false)

    post toggle_alert_rule_path(server_key: @key, id: rule.id)

    assert rule.reload.enabled
  end

  test "destroy removes the rule and its events" do
    rule = create_rule(firing: true)
    rule.alert_events.create!(
      server: @server, state: "firing", started_at: 5.minutes.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label
    )

    assert_difference("AlertRule.count", -1) do
      delete alert_rule_path(server_key: @key, id: rule.id)
    end

    assert_equal 0, AlertEvent.where(server_id: @server.id).count
    assert_redirected_to alerts_path(server_key: @key)
  end

  test "defaults seeds the starter pack idempotently" do
    assert_difference("AlertRule.count", 3) do
      post defaults_alert_rules_path(server_key: @key)
    end

    assert_no_difference("AlertRule.count") do
      post defaults_alert_rules_path(server_key: @key)
    end
  end

  test "editing a rule from the Rules tab returns there (return_to threaded through)" do
    rule = create_rule
    origin = alerts_path(server_key: @key, tab: "rules")

    get edit_alert_rule_path(server_key: @key, id: rule.id, return_to: origin)

    assert_response :success
    # The form must carry the origin forward: a hidden field for the PATCH, and
    # the Cancel / close links pointing back at it (not the default /alerts).
    assert_includes response.body, "name=\"return_to\" value=\"#{origin}\""
  end

  test "update honours return_to and lands back on that path" do
    rule = create_rule
    origin = alerts_path(server_key: @key, tab: "rules")

    patch alert_rule_path(server_key: @key, id: rule.id), params: {
      return_to: origin,
      alert_rule: {
        name: rule.name, metric_kind: "cpu", target: "host",
        comparator: "gte", threshold: "95", duration_seconds: "300"
      }
    }

    assert_redirected_to origin
  end

  test "create honours return_to" do
    origin = alerts_path(server_key: @key, tab: "rules")

    post alert_rules_path(server_key: @key), params: {
      return_to: origin,
      alert_rule: {
        name: "reqs", metric_kind: "req_s", target: "pod|#{@server.id}|clowk|web",
        comparator: "gte", threshold: "50", duration_seconds: "120"
      }
    }

    assert_redirected_to origin
  end

  test "toggle honours return_to" do
    rule = create_rule
    origin = alerts_path(server_key: @key, tab: "rules")

    post toggle_alert_rule_path(server_key: @key, id: rule.id), params: {return_to: origin}

    assert_redirected_to origin
  end

  test "an off-site return_to is rejected (no open redirect) and falls back to /alerts" do
    rule = create_rule

    post toggle_alert_rule_path(server_key: @key, id: rule.id),
      params: {return_to: "https://evil.example.com/phish"}

    # url_from refuses a cross-host target, so we land on the safe default —
    # NEVER redirect the operator off-site because a link said so.
    assert_redirected_to alerts_path(server_key: @key)
    assert_not_equal "https://evil.example.com/phish", response.location
  end

  test "another server in the SAME org CAN address the rule (alerts are org-level)" do
    rule = create_rule # targets alpha, owned by acme
    beta_key = servers(:beta).key # beta is in acme too

    post toggle_alert_rule_path(server_key: beta_key, id: rule.id)

    assert_redirected_to alerts_path(server_key: beta_key)
    assert_not rule.reload.enabled, "a sibling server in the org shares the org's rules"
  end

  test "a server in ANOTHER org cannot address the rule (cross-org guard)" do
    rule = create_rule # acme
    gamma = servers(:gamma) # globex — a different org

    post toggle_alert_rule_path(org_id: gamma.org.short_id, server_key: gamma.key, id: rule.id)

    assert rule.reload.enabled, "cross-org toggle must never touch another org's rule"
  end

  private

  def create_rule(firing: false)
    @server.alert_rules.create!(
      name: "Host CPU ≥ 90%", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300,
      firing: firing, firing_since: firing ? 5.minutes.ago : nil
    )
  end
end
