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
end
