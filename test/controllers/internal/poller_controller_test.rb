# frozen_string_literal: true

require "test_helper"

module Internal
  class PollerControllerTest < ActionDispatch::IntegrationTest
    fixtures :islands

    INTERNAL_TOKEN = "test-internal-token-aaaaaaaaaaaaaaaa"

    setup do
      # Use the ENV path (no need to monkey with credentials in
      # tests). The controller's auth lookup is creds -> ENV -> fail,
      # and the creds key isn't set in the test fixture so ENV wins.
      ENV["POLLER_TOKEN"] = INTERNAL_TOKEN
    end

    teardown do
      ENV.delete("POLLER_TOKEN")
    end

    test "returns 401 without X-Voodu-Internal-Token header" do
      get internal_poller_islands_path

      assert_response :unauthorized
    end

    test "returns 401 with wrong token" do
      get internal_poller_islands_path,
          headers: { "X-Voodu-Internal-Token" => "nope" }

      assert_response :unauthorized
    end

    test "returns 200 + island roster with right token from loopback" do
      get internal_poller_islands_path,
          headers: { "X-Voodu-Internal-Token" => INTERNAL_TOKEN }

      assert_response :ok

      body = JSON.parse(response.body)
      assert_equal 1, body["version"]
      assert_kind_of Array, body["islands"]
      assert_operator body["islands"].length, :>=, 2

      sample = body["islands"].find { |i| i["key"] == "aaaaaa" }
      assert sample, "expected fixture island alpha in response"
      assert_equal "http://10.0.0.1:8687", sample["endpoint"]
      assert_equal "pat-alpha-secret", sample["pat"]
      # id is stringified on the wire so the Go decoder (which uses
      # string as the natural type for a path component) doesn't
      # explode on a JSON number. AR keeps it as Integer internally.
      assert sample["id"].is_a?(String)
      assert_match(/\A\d+\z/, sample["id"])
    end

    test "returns 403 for non-loopback non-private IP even with right token" do
      get internal_poller_islands_path,
          headers: {
            "X-Voodu-Internal-Token" => INTERNAL_TOKEN,
            "REMOTE_ADDR" => "203.0.113.7"
          }

      assert_response :forbidden
    end

    test "returns 401 when no token is configured anywhere" do
      ENV.delete("POLLER_TOKEN")

      get internal_poller_islands_path,
          headers: { "X-Voodu-Internal-Token" => "anything" }

      assert_response :unauthorized
    end
  end
end
