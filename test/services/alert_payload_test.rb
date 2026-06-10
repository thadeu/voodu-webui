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
    @island.alert_destinations.new({ name: "d", kind: kind }.merge(attrs))
  end

  test "slack payload is a text message naming rule, state and value" do
    p = AlertPayload.for(@event, "firing", dest("slack", endpoint: "https://hooks.slack.com/services/T/B/X"))

    assert p.key?(:text)
    assert_includes p[:text], "Host CPU ≥ 90%"
    assert_includes p[:text], "firing"
    assert_includes p[:text], "95%"
  end

  test "resolved slack payload reads resolved" do
    d = dest("slack", endpoint: "https://hooks.slack.com/services/T/B/X")
    assert_includes AlertPayload.for(@event, "resolved", d)[:text], "resolved"
  end

  test "telegram payload carries chat_id and a plain text line" do
    p = AlertPayload.for(@event, "firing", dest("telegram", secret: "1:AA", chat_id: "555"))

    assert_equal "555", p[:chat_id]
    assert_includes p[:text], "Host CPU ≥ 90%"
    assert_includes p[:text], "95%"
    assert_not p.key?(:parse_mode), "plain text — no markdown escaping pitfalls"
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
