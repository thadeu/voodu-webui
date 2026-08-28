# frozen_string_literal: true

require "test_helper"

# DataTable::HttpFetch fires an operator-supplied URL server-side, from inside
# the private network that holds every voodu controller and this app's own
# /internal/poller endpoints — the endpoint that hands out decrypted PATs. That
# makes it a request primitive, and it shipped with no SSRF guard at all while
# WebhookClient (the other outbound path) had one.
#
# Never raises to the caller: a refusal is a Result with ok? == false, the same
# shape as a timeout or a bad URL, so a dashboard panel renders the message
# instead of 500ing.
module DataTable
  class HttpFetchTest < ActiveSupport::TestCase
    test "reaches a public host" do
      stub = stub_request(:get, "https://api.example.com/rows").to_return(
        status: 200, body: "[]", headers: {"Content-Type" => "application/json"}
      )

      result = HttpFetch.call(url: "https://api.example.com/rows")

      assert result.ok?, result.error
      assert_requested stub
    end

    test "allows private hosts when permitted (the self-hosted default in dev)" do
      stub = stub_request(:get, "http://10.0.0.5/rows").to_return(
        status: 200, body: "[]", headers: {"Content-Type" => "application/json"}
      )

      assert HttpFetch.call(url: "http://10.0.0.5/rows").ok?
      assert_requested stub
    end

    test "refuses loopback, private and link-local when private hosts are not permitted" do
      block_private do
        # 169.254.169.254 is the cloud metadata address — the canonical SSRF
        # target, and the reason this guard is not merely tidiness.
        ["http://127.0.0.1/rows", "http://10.0.0.5/rows", "http://169.254.169.254/latest"].each do |url|
          result = HttpFetch.call(url: url)

          assert_not result.ok?, "#{url} must be refused"
          assert_includes result.error, "non-routable"
        end
      end

      assert_not_requested :get, %r{.*}
    end

    test "refuses the app's own internal poller endpoint" do
      block_private do
        result = HttpFetch.call(url: "http://127.0.0.1:3000/internal/poller/servers")

        assert_not result.ok?
      end
    end

    test "refuses a non-http scheme" do
      result = HttpFetch.call(url: "file:///etc/passwd")

      assert_not result.ok?
      assert_includes result.error, "http(s)"
    end

    private

    def block_private
      original = HttpFetch.method(:allow_private_hosts?)
      HttpFetch.define_singleton_method(:allow_private_hosts?) { false }
      yield
    ensure
      HttpFetch.define_singleton_method(:allow_private_hosts?, original)
    end
  end
end
