# frozen_string_literal: true

require "test_helper"

class AlertRuleTest < ActiveSupport::TestCase
  fixtures :islands

  setup do
    @island = islands(:alpha)
  end

  test "valid host rule saves" do
    rule = @island.alert_rules.new(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )

    assert rule.valid?, rule.errors.full_messages.join(", ")
  end

  test "pod target requires scope and name" do
    rule = @island.alert_rules.new(
      name: "pod cpu", metric_kind: "cpu", target_kind: "pod",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )

    assert_not rule.valid?
    assert rule.errors[:target_scope].any?
    assert rule.errors[:target_name].any?
  end

  test "disk is host-only" do
    rule = @island.alert_rules.new(
      name: "pod disk", metric_kind: "disk", target_kind: "pod",
      target_scope: "clowk", target_name: "web",
      comparator: "gte", threshold: 85, duration_seconds: 300
    )

    assert_not rule.valid?
    assert rule.errors[:target_kind].any?
  end

  test "req_s is deployment-only" do
    rule = @island.alert_rules.new(
      name: "host reqs", metric_kind: "req_s", target_kind: "host",
      comparator: "gte", threshold: 50, duration_seconds: 300
    )

    assert_not rule.valid?
    assert rule.errors[:target_kind].any?
  end

  test "percent metrics cap threshold at 100, req_s does not" do
    over = @island.alert_rules.new(
      name: "over", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 150, duration_seconds: 300
    )
    assert_not over.valid?

    rate = @island.alert_rules.new(
      name: "rate", metric_kind: "req_s", target_kind: "pod",
      target_scope: "clowk", target_name: "web",
      comparator: "gte", threshold: 150, duration_seconds: 300
    )
    assert rate.valid?, rate.errors.full_messages.join(", ")
  end

  test "name is unique per island but reusable across islands" do
    @island.alert_rules.create!(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )

    dup = @island.alert_rules.new(
      name: "cpu", metric_kind: "memory", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )
    assert_not dup.valid?

    other = islands(:beta).alert_rules.new(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )
    assert other.valid?
  end

  test "create_defaults! is idempotent and keeps operator tweaks" do
    first = AlertRule.create_defaults!(@island)
    assert_equal 3, first.size
    assert_equal 3, @island.alert_rules.count

    @island.alert_rules.find_by!(name: "Host CPU ≥ 90%").update!(threshold: 75)

    AlertRule.create_defaults!(@island)
    assert_equal 3, @island.alert_rules.count
    assert_equal 75.0, @island.alert_rules.find_by!(name: "Host CPU ≥ 90%").threshold
  end

  test "firing_count_for counts only enabled firing rules" do
    make = lambda do |name, firing:, enabled:|
      @island.alert_rules.create!(
        name: name, metric_kind: "cpu", target_kind: "host",
        comparator: "gte", threshold: 90, duration_seconds: 300,
        firing: firing, enabled: enabled
      )
    end
    make.("a", firing: true,  enabled: true)
    make.("b", firing: true,  enabled: false)
    make.("c", firing: false, enabled: true)

    assert_equal 1, AlertRule.firing_count_for(@island.id)
  end

  test "disable! resolves the open event and clears firing" do
    rule = @island.alert_rules.create!(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300,
      firing: true, firing_since: 10.minutes.ago
    )
    event = rule.alert_events.create!(
      island: @island, state: "firing", started_at: 10.minutes.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label
    )

    rule.disable!

    assert_not rule.reload.enabled
    assert_not rule.firing
    assert_equal "resolved", event.reload.state
    assert_not_nil event.resolved_at
  end

  test "format_metric_value renders unit by metric kind" do
    assert_equal "92.3%", AlertRule.format_metric_value(92.31, "cpu")
    assert_equal "90%", AlertRule.format_metric_value(90.0, "disk")
    assert_equal "3.2 req/s", AlertRule.format_metric_value(3.21, "req_s")
    assert_equal "—", AlertRule.format_metric_value(nil, "cpu")
  end

  test "metrics_link_params points host rules at the host scope" do
    rule = @island.alert_rules.new(metric_kind: "cpu", target_kind: "host")

    assert_equal({ scope_kind: "host" }, rule.metrics_link_params)
  end

  test "metrics_link_params resolves a pod rule to a live replica container" do
    rule = @island.alert_rules.create!(
      name: "ctrl", metric_kind: "cpu", target_kind: "pod",
      target_scope: "fsw", target_name: "controller",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )
    @island.pods.create!(
      scope: "fsw", resource_name: "controller", container_name: "fsw-controller.e1e1",
      kind: "deployment", replica_id: "e1e1", payload: "{}", synced_at: Time.current
    )

    assert_equal({ scope_kind: "pod", scope_id: "fsw-controller.e1e1" }, rule.metrics_link_params)
  end

  test "metrics_link_params falls back to host when the deployment has no live replica" do
    rule = @island.alert_rules.create!(
      name: "ctrl", metric_kind: "cpu", target_kind: "pod",
      target_scope: "fsw", target_name: "controller",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )

    assert_equal({ scope_kind: "host" }, rule.metrics_link_params)
  end

  test "destinations_for: no selection notifies all enabled destinations wanting the transition" do
    rule = @island.alert_rules.create!(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )
    firing_only = @island.alert_destinations.create!(
      name: "a", kind: "webhook", endpoint: "https://a.example/h", on_firing: true, on_resolved: false
    )
    both = @island.alert_destinations.create!(
      name: "b", kind: "webhook", endpoint: "https://b.example/h", on_firing: true, on_resolved: true
    )
    disabled = @island.alert_destinations.create!(
      name: "c", kind: "webhook", endpoint: "https://c.example/h", enabled: false
    )

    assert_equal [firing_only.id, both.id].sort, rule.destinations_for("firing").map(&:id).sort
    assert_equal [both.id], rule.destinations_for("resolved").map(&:id)
    assert_not_includes rule.destinations_for("firing").map(&:id), disabled.id
  end

  test "destinations_for: an explicit subset overrides the all-default" do
    rule = @island.alert_rules.create!(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )
    a = @island.alert_destinations.create!(name: "a", kind: "webhook", endpoint: "https://a.example/h")
    @island.alert_destinations.create!(name: "b", kind: "webhook", endpoint: "https://b.example/h")
    rule.update!(alert_destinations: [a])

    assert_equal [a.id], rule.destinations_for("firing").map(&:id)
  end

  test "condition_label composes comparator, value and duration" do
    rule = @island.alert_rules.new(
      metric_kind: "disk", comparator: "gte", threshold: 85, duration_seconds: 300
    )

    assert_equal "≥ 85% for 5m", rule.condition_label
  end
end
