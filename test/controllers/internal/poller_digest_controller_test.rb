# frozen_string_literal: true

require "test_helper"

module Internal
  class PollerDigestControllerTest < ActionDispatch::IntegrationTest
    fixtures :islands

    INTERNAL_TOKEN = "test-internal-token-aaaaaaaaaaaaaaaa"
    VALID_HASH     = "0123456789abcdef"

    setup do
      ENV["POLLER_TOKEN"] = INTERNAL_TOKEN
    end

    teardown do
      ENV.delete("POLLER_TOKEN")
      PollerDigest.delete_all
    end

    test "returns 401 without X-Voodu-Internal-Token header" do
      post internal_poller_digest_path,
           params: { type: "metrics", tenant_id: islands(:alpha).id, sync_hash: VALID_HASH }

      assert_response :unauthorized
    end

    test "returns 401 with wrong token" do
      post internal_poller_digest_path,
           params: valid_params,
           headers: { "X-Voodu-Internal-Token" => "nope" }

      assert_response :unauthorized
    end

    test "returns 403 from non-loopback non-private IP" do
      post internal_poller_digest_path,
           params: valid_params,
           headers: {
             "X-Voodu-Internal-Token" => INTERNAL_TOKEN,
             "REMOTE_ADDR"            => "203.0.113.7"
           }

      assert_response :forbidden
    end

    test "returns 202 + enqueues PollerDigestJob with right token" do
      assert_enqueued_with(job: PollerDigestJob, args: [VALID_HASH]) do
        post internal_poller_digest_path,
             params: valid_params,
             headers: token_header
      end

      assert_response :accepted

      body = JSON.parse(response.body)
      assert_equal "queued", body["status"]
      assert_equal VALID_HASH, body["sync_hash"]

      digest = PollerDigest.find_by(sync_hash: VALID_HASH)
      assert digest
      assert_equal "metrics", digest.type
      assert_equal islands(:alpha).id, digest.tenant_id
      assert_equal "queued", digest.status
    end

    test "returns 200 duplicate and does NOT enqueue when sync_hash exists" do
      PollerDigest.create!(
        sync_hash: VALID_HASH,
        type:      "metrics",
        tenant_id: islands(:alpha).id,
        status:    "processed"
      )

      assert_no_enqueued_jobs only: PollerDigestJob do
        post internal_poller_digest_path,
             params: valid_params,
             headers: token_header
      end

      assert_response :ok
      body = JSON.parse(response.body)
      assert_equal "duplicate", body["status"]
    end

    test "returns 400 on invalid type" do
      post internal_poller_digest_path,
           params: valid_params.merge(type: "wat"),
           headers: token_header

      assert_response :bad_request
    end

    test "returns 400 on bad sync_hash shape" do
      post internal_poller_digest_path,
           params: valid_params.merge(sync_hash: "NOT-HEX"),
           headers: token_header

      assert_response :bad_request
    end

    test "returns 400 when tenant_id missing" do
      post internal_poller_digest_path,
           params: valid_params.except(:tenant_id),
           headers: token_header

      assert_response :bad_request
    end

    private

    def valid_params
      {
        type:      "metrics",
        tenant_id: islands(:alpha).id,
        sync_hash: VALID_HASH,
        ts:        1_716_922_000_000,
        size:      12_345
      }
    end

    def token_header
      { "X-Voodu-Internal-Token" => INTERNAL_TOKEN }
    end
  end
end
