# frozen_string_literal: true

require "test_helper"

class EgressIpTest < ActiveSupport::TestCase
  setup { Rails.cache.delete(EgressIp::CACHE_KEY) }

  test "APP_EGRESS_IP wins over the lookup" do
    stub_request(:get, EgressIp::REFLECTOR).to_return(status: 200, body: "203.0.113.9\n")

    with_env("APP_EGRESS_IP" => "198.51.100.4") do
      assert_equal "198.51.100.4", EgressIp.current
    end
  end

  test "the reflector's answer is trimmed and validated" do
    stub_request(:get, EgressIp::REFLECTOR).to_return(status: 200, body: "203.0.113.9\n")

    assert_equal "203.0.113.9", EgressIp.current
  end

  test "garbage or a dead reflector yields nil, never an exception" do
    stub_request(:get, EgressIp::REFLECTOR).to_return(status: 200, body: "<html>nope</html>")
    assert_nil EgressIp.current

    Rails.cache.delete(EgressIp::CACHE_KEY)
    stub_request(:get, EgressIp::REFLECTOR).to_timeout
    assert_nil EgressIp.current
  end

  test "firewall_hint names the port and the address" do
    stub_request(:get, EgressIp::REFLECTOR).to_return(status: 200, body: "203.0.113.9")
    server = Server.new(endpoint: "https://edge.example.com:8687")

    hint = ServerHealth.firewall_hint(server)

    assert_includes hint, "edge.example.com:8687"
    assert_includes hint, "Allow inbound TCP 8687 from 203.0.113.9"
  end

  private

  def with_env(pairs)
    saved = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end
