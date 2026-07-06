# frozen_string_literal: true

require "test_helper"

class AlertEventTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @rule = @server.alert_rules.create!(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )
  end

  def event(rule = @rule)
    rule.alert_events.create!(
      server: @server, state: "firing", started_at: 1.minute.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu", target_label: "host alpha"
    )
  end

  test "to_dedup_key is a sha256 hex, not the raw id" do
    e = event
    assert_match(/\A[0-9a-f]{64}\z/, e.to_dedup_key)
    assert_not_equal e.id.to_s, e.to_dedup_key
  end

  test "to_dedup_key is stable for the same episode and unique per episode" do
    e = event
    assert_equal e.to_dedup_key, e.reload.to_dedup_key

    other_rule = @server.alert_rules.create!(
      name: "mem", metric_kind: "memory", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )
    assert_not_equal e.to_dedup_key, event(other_rule).to_dedup_key
  end
end
