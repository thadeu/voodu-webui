# frozen_string_literal: true

require "test_helper"

module Internal
  # Covers GET /internal/poller/metrics_watermark — the cold-start resume
  # point the Go poller asks for so it backfills the offline gap instead of
  # restarting at now-30s. Auth/IP guards are shared with PollerController
  # (covered in poller_controller_test); here we pin the watermark math +
  # per-island isolation.
  class PollerMetricsWatermarkTest < ActionDispatch::IntegrationTest
    fixtures :orgs, :islands

    INTERNAL_TOKEN = "test-internal-token-aaaaaaaaaaaaaaaa"

    setup do
      ENV["POLLER_TOKEN"] = INTERNAL_TOKEN
      MetricSample.delete_all
    end

    teardown do
      ENV.delete("POLLER_TOKEN")
      MetricSample.delete_all
    end

    test "requires a tenant_id" do
      get internal_poller_metrics_watermark_path,
        headers: {"X-Voodu-Internal-Token" => INTERNAL_TOKEN}

      assert_response :bad_request
    end

    test "returns since=0 when the warehouse is empty for this island" do
      get internal_poller_metrics_watermark_path(tenant_id: islands(:alpha).id),
        headers: {"X-Voodu-Internal-Token" => INTERNAL_TOKEN}

      assert_response :ok

      body = JSON.parse(response.body)
      assert_equal 1, body["version"]
      assert_equal 0, body["since"]
    end

    test "returns the newest ts_epoch for the island, isolated per tenant" do
      base = Time.utc(2026, 6, 18, 8, 0, 0)
      seed(islands(:alpha).id, base, base + 15, base + 30)
      # beta has a LATER sample — must not bleed into alpha's watermark.
      seed(islands(:beta).id, base + 3600)

      get internal_poller_metrics_watermark_path(tenant_id: islands(:alpha).id),
        headers: {"X-Voodu-Internal-Token" => INTERNAL_TOKEN}

      assert_response :ok

      body = JSON.parse(response.body)
      assert_equal (base + 30).to_i, body["since"]
    end

    test "401 without the internal token" do
      get internal_poller_metrics_watermark_path(tenant_id: islands(:alpha).id)

      assert_response :unauthorized
    end

    private

    def seed(tenant_id, *times)
      rows = times.map do |t|
        {
          tenant_id: tenant_id,
          source: "system",
          ts_iso: t.strftime("%Y-%m-%dT%H:%M:%SZ"),
          payload: %({"cpu_percent":1.0})
        }
      end

      MetricSample.bulk_insert(rows)
    end
  end
end
