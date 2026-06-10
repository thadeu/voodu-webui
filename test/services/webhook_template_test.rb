# frozen_string_literal: true

require "test_helper"

class WebhookTemplateTest < ActiveSupport::TestCase
  test "substitutes tokens in string values across nested structures" do
    out = WebhookTemplate.render(
      '{"text":"{{rule}} {{state}}","nested":{"who":"{{target}}"},"list":["{{metric}}"]}',
      { "rule" => "Host CPU", "state" => "firing", "target" => "host x", "metric" => "cpu" }
    )

    parsed = JSON.parse(out)
    assert_equal "Host CPU firing", parsed["text"]
    assert_equal "host x", parsed.dig("nested", "who")
    assert_equal ["cpu"], parsed["list"]
  end

  test "escapes values that contain JSON-significant characters" do
    out = WebhookTemplate.render('{"t":"{{target}}"}', { "target" => 'host "fsw"' })

    # The rendered string is valid JSON and round-trips the quote.
    assert_equal 'host "fsw"', JSON.parse(out)["t"]
    assert_includes out, '\\"fsw\\"'
  end

  test "leaves unknown tokens literal" do
    out = WebhookTemplate.render('{"t":"{{nope}}"}', { "rule" => "x" })
    assert_equal "{{nope}}", JSON.parse(out)["t"]
  end

  test "nil token values render as empty strings" do
    out = WebhookTemplate.render('{"t":"[{{resolved_at}}]"}', { "resolved_at" => nil })
    assert_equal "[]", JSON.parse(out)["t"]
  end

  test "numbers are templated as strings" do
    out = WebhookTemplate.render('{"v":"{{value}}"}', { "value" => 92.5 })
    assert_equal "92.5", JSON.parse(out)["v"]
  end

  test "slice filter takes a substring (Liquid semantics)" do
    out = WebhookTemplate.render('{"k":"{{dedup_key | slice: 0, 6}}"}',
                                 { "dedup_key" => "a3f9c2d1e0ffaa" })
    assert_equal "a3f9c2", JSON.parse(out)["k"]
  end

  test "whitespace around token and pipes is tolerated" do
    out = WebhookTemplate.render('{"r":"{{ rule | upcase }}"}', { "rule" => "host cpu" })
    assert_equal "HOST CPU", JSON.parse(out)["r"]
  end

  test "filters chain left to right" do
    out = WebhookTemplate.render('{"t":"{{target | slice: 0, 3 | upcase}}"}', { "target" => "fsw/api" })
    assert_equal "FSW", JSON.parse(out)["t"]
  end

  test "default filter fills an empty value" do
    out = WebhookTemplate.render('{"r":"{{resolved_at | default: n/a}}"}', { "resolved_at" => "" })
    assert_equal "n/a", JSON.parse(out)["r"]
  end

  test "unknown filter is a no-op, not an error" do
    out = WebhookTemplate.render('{"r":"{{rule | system: rm -rf}}"}', { "rule" => "x" })
    assert_equal "x", JSON.parse(out)["r"]
  end

  test "a filter with wrong arity leaves the value untouched" do
    out = WebhookTemplate.render('{"r":"{{rule | slice}}"}', { "rule" => "host cpu" })
    assert_equal "host cpu", JSON.parse(out)["r"]
  end

  test "filter output is still JSON-escaped" do
    out = WebhookTemplate.render('{"r":"{{rule | upcase}}"}', { "rule" => 'a "b"' })
    assert_equal 'A "B"', JSON.parse(out)["r"]
  end

  test "no Ruby is evaluated — method-call syntax stays literal data" do
    # `.to_s[0..6]` is not our syntax; it must NOT execute, just render.
    out = WebhookTemplate.render('{"k":"{{dedup_key}}.to_s[0..6]"}', { "dedup_key" => "abcdef123" })
    assert_equal "abcdef123.to_s[0..6]", JSON.parse(out)["k"]
  end
end
