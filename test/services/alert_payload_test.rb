# frozen_string_literal: true

require "test_helper"

class AlertPayloadTest < ActiveSupport::TestCase
  fixtures :islands

  setup do
    @island = islands(:alpha)
    @event = AlertEvent.new(
      island: @island, state: "firing", started_at: Time.utc(2026, 6, 10, 12),
      threshold: 90, rule_name: "Host CPU ≥ 90%", metric_kind: "cpu",
      target_label: "host alpha", peak_value: 97.0, last_value: 95.0
    )
  end

  def dest(kind, **attrs)
    @island.alert_destinations.new({name: "d", kind: kind}.merge(attrs))
  end

  test "webhook with a body template renders it to a verbatim JSON string" do
    d = dest("webhook", endpoint: "https://x.example/h",
      body_template: '{"text":"{{rule}} {{state}}","v":"{{value}}{{unit}}"}')
    out = AlertPayload.for(@event, "firing", d)

    assert_kind_of String, out
    parsed = JSON.parse(out)
    assert_equal "Host CPU ≥ 90% firing", parsed["text"]
    assert_equal "95%", parsed["v"]
  end

  test "pagerduty tokens: event_action flips, dedup_key is the stable episode id" do
    d = dest("webhook", endpoint: "https://x.example/h",
      body_template: '{"action":"{{event_action}}","key":"{{dedup_key}}"}')

    # Same persisted event → same dedup_key across both transitions, so
    # a resolve closes the incident the trigger opened.
    rule = @island.alert_rules.create!(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )
    ev = rule.alert_events.create!(
      island: @island, state: "firing", started_at: 1.minute.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu", target_label: "host alpha"
    )

    firing = JSON.parse(AlertPayload.for(ev, "firing", d))
    resolved = JSON.parse(AlertPayload.for(ev, "resolved", d))

    assert_equal "trigger", firing["action"]
    assert_equal "resolve", resolved["action"]
    assert_equal ev.to_dedup_key, firing["key"]
    assert_equal firing["key"], resolved["key"], "dedup_key stable across transitions"
    assert_not_equal ev.id.to_s, firing["key"], "opaque hash, not the raw id"
    assert_match(/\A[0-9a-f]{64}\z/, firing["key"], "sha256 hex")
  end

  test "template tokens round noisy numbers and humanise the date" do
    @event.last_value = 23.24981689453125
    d = dest("webhook", endpoint: "https://x.example/h",
      body_template: '{"v":"{{value}}","d":"{{started_at}}"}')
    parsed = JSON.parse(AlertPayload.for(@event, "firing", d))

    assert_equal "23.2", parsed["v"], "rounded to 1 decimal, no float noise"
    assert_no_match(/T.*Z/, parsed["d"], "humanised — not a raw ISO timestamp")
    assert_match(/\w{3} \d/, parsed["d"], "month abbrev + day, e.g. 'Jun 10'")
  end

  test "webhook payload is a structured object" do
    p = AlertPayload.for(@event, "firing", dest("webhook", endpoint: "https://x.example/h"))

    assert_equal "firing", p[:event]
    assert_equal "Host CPU ≥ 90%", p[:rule]
    assert_equal "host alpha", p[:target]
    assert_equal "cpu", p[:metric]
    assert_equal 90, p[:threshold]
    assert_equal 95.0, p[:value]
    assert_equal "alpha", p[:island]
  end

  test "link is included only when APP_BASE_URL is set" do
    d = dest("webhook", endpoint: "https://x.example/h")
    assert_nil AlertPayload.for(@event, "firing", d)[:url]

    ENV["APP_BASE_URL"] = "https://voodu.example"
    p = AlertPayload.for(@event, "firing", d)
    assert_equal "https://voodu.example/#{@island.key}/alerts", p[:url]
  ensure
    ENV.delete("APP_BASE_URL")
  end
end
