# frozen_string_literal: true

require "test_helper"

class WebhookClientTest < ActiveSupport::TestCase
  # A public IP literal so the SSRF guard takes the no-DNS path —
  # deterministic and offline (WebMock stubs HTTP, not DNS).
  PUBLIC = "93.184.216.34"

  test "posts JSON to a public https host" do
    stub = stub_request(:post, "https://#{PUBLIC}/hook")
      .with(headers: {"Content-Type" => "application/json"}, body: {x: 1}.to_json)
      .to_return(status: 200)

    WebhookClient.post("https://#{PUBLIC}/hook", {x: 1})

    assert_requested stub
  end

  test "sends custom auth headers" do
    stub = stub_request(:post, "https://#{PUBLIC}/hook")
      .with(headers: {"x-api-key" => "abc123"})
      .to_return(status: 200)

    WebhookClient.post("https://#{PUBLIC}/hook", {x: 1}, headers: {"x-api-key" => "abc123"})

    assert_requested stub
  end

  test "allows http URLs (local/internal endpoints)" do
    stub = stub_request(:post, "http://#{PUBLIC}/hook").to_return(status: 200)
    WebhookClient.post("http://#{PUBLIC}/hook", {x: 1})
    assert_requested stub
  end

  test "rejects non-http(s) schemes" do
    err = assert_raises(WebhookClient::BlockedError) do
      WebhookClient.post("ftp://#{PUBLIC}/hook", {})
    end
    assert_includes err.message, "http"
  end

  test "allows private/loopback hosts when permitted (dev default)" do
    stub = stub_request(:post, "http://10.0.0.5/hook").to_return(status: 200)
    WebhookClient.post("http://10.0.0.5/hook", {})
    assert_requested stub
  end

  test "blocks loopback, private and link-local when private hosts are not permitted" do
    block_private do
      assert_raises(WebhookClient::BlockedError) { WebhookClient.post("https://127.0.0.1/hook", {}) }
      assert_raises(WebhookClient::BlockedError) { WebhookClient.post("https://10.0.0.5/hook", {}) }
      assert_raises(WebhookClient::BlockedError) { WebhookClient.post("https://169.254.169.254/latest", {}) }
    end
  end

  test "blocks a hostname that resolves to a private address when not permitted" do
    block_private do
      with_dns("internal.example" => ["10.1.2.3"]) do
        assert_raises(WebhookClient::BlockedError) { WebhookClient.post("https://internal.example/h", {}) }
      end
    end
  end

  test "maps 4xx to ClientError (discard) and 5xx/429 to ServerError (retry)" do
    stub_request(:post, "https://#{PUBLIC}/a").to_return(status: 404)
    assert_raises(WebhookClient::ClientError) { WebhookClient.post("https://#{PUBLIC}/a", {}) }

    stub_request(:post, "https://#{PUBLIC}/b").to_return(status: 503)
    assert_raises(WebhookClient::ServerError) { WebhookClient.post("https://#{PUBLIC}/b", {}) }

    stub_request(:post, "https://#{PUBLIC}/c").to_return(status: 429)
    assert_raises(WebhookClient::ServerError) { WebhookClient.post("https://#{PUBLIC}/c", {}) }
  end

  test "wraps connection failures as TransportError" do
    stub_request(:post, "https://#{PUBLIC}/h").to_raise(Faraday::ConnectionFailed.new("boom"))
    assert_raises(WebhookClient::TransportError) { WebhookClient.post("https://#{PUBLIC}/h", {}) }
  end

  private

  # Swap Resolv.getaddresses for the block (the suite uses manual
  # singleton-method swaps rather than minitest/mock's stub).
  def with_dns(map)
    original = Resolv.method(:getaddresses)
    Resolv.define_singleton_method(:getaddresses) { |host| map.fetch(host.to_s, []) }
    yield
  ensure
    Resolv.define_singleton_method(:getaddresses, original)
  end

  # Simulate the production posture (private hosts blocked) regardless
  # of the test env, via the same manual singleton swap.
  def block_private
    original = WebhookClient.method(:allow_private_hosts?)
    WebhookClient.define_singleton_method(:allow_private_hosts?) { false }
    yield
  ensure
    WebhookClient.define_singleton_method(:allow_private_hosts?, original)
  end
end
