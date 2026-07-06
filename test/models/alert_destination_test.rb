# frozen_string_literal: true

require "test_helper"

class AlertDestinationTest < ActiveSupport::TestCase
  fixtures :orgs, :islands

  setup { @island = islands(:alpha) }

  def build(**attrs)
    @island.org.alert_destinations.new({
      name: "d", kind: "webhook", endpoint: "https://example.com/h",
      on_firing: true, on_resolved: true
    }.merge(attrs))
  end

  test "valid webhook destination saves" do
    assert build.valid?
  end

  test "kind must be known" do
    assert_not build(kind: "carrier-pigeon").valid?
  end

  test "webhook endpoint may be http (local/internal APIs)" do
    assert build(endpoint: "http://localhost:4000/hook").valid?
    assert build(endpoint: "https://example.com/h").valid?
  end

  test "endpoint must be a valid http(s) URL" do
    d = build(endpoint: "ftp://example.com/h")
    assert_not d.valid?
    assert_includes d.errors[:endpoint].first, "http"
  end

  test "at least one trigger required" do
    d = build(on_firing: false, on_resolved: false)
    assert_not d.valid?
    assert d.errors[:base].any?
  end

  test "name unique per org, reusable across orgs" do
    @island.org.alert_destinations.create!(name: "ops", kind: "webhook", endpoint: "https://a.com/h")
    assert_not build(name: "ops").valid?
    # beta shares alpha's org (acme) → "ops" collides; gamma is a different org
    # (globex) → the same name is free there.
    assert_not islands(:beta).org.alert_destinations.new(name: "ops", kind: "webhook", endpoint: "https://a.com/h").valid?
    assert islands(:gamma).org.alert_destinations.new(name: "ops", kind: "webhook", endpoint: "https://a.com/h").valid?
  end

  test "endpoint and secret round-trip through encryption" do
    d = @island.org.alert_destinations.create!(
      name: "enc", kind: "webhook", endpoint: "https://example.com/secret", secret: "shh"
    )
    assert_equal "https://example.com/secret", d.reload.endpoint
    assert_equal "shh", d.secret
  end

  test "notifies? respects the per-transition toggles" do
    d = build(on_firing: true, on_resolved: false)
    assert d.notifies?("firing")
    assert_not d.notifies?("resolved")
  end

  test "webhook body_template must be valid JSON when present" do
    bad = build(body_template: "{not json")
    assert_not bad.valid?
    assert_includes bad.errors[:body_template].first, "valid JSON"

    assert build(body_template: '{"text":"{{rule}}"}').valid?
    assert build(body_template: nil).valid?
  end

  test "custom_body? is true only with a body template" do
    assert build(body_template: '{"a":1}').custom_body?
    assert_not build(body_template: nil).custom_body?
  end

  test "auth_header builds the custom header when name and value are set" do
    d = build(secret_header: "x-api-key", secret: "abc123")
    assert_equal({"x-api-key" => "abc123"}, d.auth_header)
  end

  test "auth_header is empty when either name or value is missing" do
    assert_equal({}, build(secret_header: "Authorization", secret: nil).auth_header)
    assert_equal({}, build(secret_header: nil, secret: "Bearer x").auth_header)
  end

  test "auth_header carries arbitrary schemes verbatim" do
    d = build(secret_header: "Authorization", secret: 'Token token="xyz"')
    assert_equal({"Authorization" => 'Token token="xyz"'}, d.auth_header)
  end

  test "endpoint_masked hides the path/token" do
    assert_equal "https://hooks.slack.com/…",
      build(endpoint: "https://hooks.slack.com/services/T/B/SECRET").endpoint_masked
  end
end
