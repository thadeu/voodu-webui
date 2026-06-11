# frozen_string_literal: true

require "test_helper"

# Pins PodDetailData#probes — the manifest-spec parsing that feeds
# Components::Pods::ProbesCard. Runs in warehouse mode (same headless
# pattern as MetricDashboardDataTest) so we seed the pod's payload row
# directly instead of needing a live controller. We assert the parsing
# contract only: order, declared-only filtering, and the empty/defensive
# shapes the view gates on (#any?).
class PodDetailDataProbesTest < ActiveSupport::TestCase
  fixtures :islands

  setup do
    @island          = islands(:alpha)
    @prev_wh         = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"
  end

  teardown { ENV["WAREHOUSE"] = @prev_wh }

  test "parses declared probes from the k8s-style envelope (spec.spec.probes)" do
    seed_pod(spec: enveloped({
      "readiness" => { "http_get" => { "path" => "/ready", "port" => 8080 }, "period" => "5s" },
      "startup"   => { "http_get" => { "path" => "/healthz", "port" => 8080 }, "failure_threshold" => 30 },
      "liveness"  => { "http_get" => { "path" => "/healthz", "port" => 8080 } }
    }))

    probes = build.probes

    assert_equal %w[liveness readiness startup], probes.map { |p| p[:kind] }
    assert_equal({ "http_get" => { "path" => "/ready", "port" => 8080 }, "period" => "5s" }, probes[1][:spec])
  end

  test "tolerates a flat spec.probes shape as a fallback" do
    seed_pod(spec: { "probes" => {
      "liveness" => { "tcp_socket" => { "port" => 5432 } }
    } })

    probes = build.probes

    assert_equal 1, probes.size
    assert_equal "liveness", probes.first[:kind]
  end

  test "empty array when no probes declared, no spec, or non-hash entries" do
    seed_pod(spec: enveloped({}).tap { |s| s["spec"].delete("probes") })
    assert_empty build.probes

    @island.pods.delete_all
    seed_pod(spec: nil)
    assert_empty build.probes

    @island.pods.delete_all
    seed_pod(spec: enveloped({ "liveness" => {}, "readiness" => "nope" }))
    assert_empty build.probes
  end

  private

  def client
    @client ||= Voodu::Client.new(@island)
  end

  # enveloped — wrap a probes hash the way the controller ships it:
  # the manifest is a k8s-style envelope and the probes block lives in
  # the inner body (spec.spec.probes).
  def enveloped(probes)
    {
      "name" => "api", "kind" => "deployment", "scope" => "fsw",
      "metadata" => {},
      "spec" => { "probes" => probes }
    }
  end

  def build
    PodDetailData.new(client, @island, "web.aaaa")
  end

  def seed_pod(spec:)
    payload = {
      "name" => "web.aaaa", "scope" => "web", "resource_name" => "web",
      "replica_id" => "aaaa", "kind" => "deployment", "status" => "running",
      "image" => "nginx:1.27"
    }
    payload["spec"] = spec unless spec.nil?

    @island.pods.create!(
      container_name: "web.aaaa",
      kind:           "deployment",
      scope:          "web",
      resource_name:  "web",
      replica_id:     "aaaa",
      synced_at:      Time.current,
      payload:        payload.to_json
    )
  end
end
