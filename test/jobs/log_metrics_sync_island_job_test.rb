# frozen_string_literal: true

require "test_helper"

# Exercises the Fase-2 counter end-to-end: seed a running pod + an NDJSON
# warehouse + a dashboard with a log-count panel, run the job, and assert it
# wrote log_count samples whose SUM equals the matches. Warehouse mode so
# IslandPods.compact reads the local pods table (no live controller), mirroring
# MetricDashboardDataTest.
class LogMetricsSyncIslandJobTest < ActiveSupport::TestCase
  fixtures :islands

  setup do
    @island = islands(:alpha)
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"
    clear_island_logs
    MetricSample.where(tenant_id: @island.id).delete_all
  end

  teardown do
    ENV["WAREHOUSE"] = @prev_wh
    clear_island_logs
    MetricSample.where(tenant_id: @island.id).delete_all
  end

  INVITE = "@message like /INVITE/"

  test "counts matching lines in the live window into log_count samples" do
    seed_running_fs_pod("fs.aaaa")
    make_log_dashboard(INVITE)
    seed_logs("fs.aaaa", [[5, "INVITE a"], [4, "200 OK"], [3, "INVITE b"]])

    LogMetricsSyncIslandJob.perform_now(@island.id)

    assert_equal 2, count_for(INVITE), "two INVITEs counted, the 200 OK excluded"
  end

  test "is idempotent — running twice does not double-count" do
    seed_running_fs_pod("fs.aaaa")
    make_log_dashboard(INVITE)
    seed_logs("fs.aaaa", [[5, "INVITE a"], [3, "INVITE b"]])

    2.times { LogMetricsSyncIslandJob.perform_now(@island.id) }

    assert_equal 2, count_for(INVITE), "recompute replaces, never adds"
  end

  test "picks up a new line on a later run (recompute absorbs it)" do
    seed_running_fs_pod("fs.aaaa")
    make_log_dashboard(INVITE)
    seed_logs("fs.aaaa", [[5, "INVITE a"]])
    LogMetricsSyncIslandJob.perform_now(@island.id)
    assert_equal 1, count_for(INVITE)

    seed_logs("fs.aaaa", [[2, "INVITE b"]])
    LogMetricsSyncIslandJob.perform_now(@island.id)

    assert_equal 2, count_for(INVITE)
  end

  test "aggregates across every replica of the workload" do
    seed_running_fs_pod("fs.aaaa")
    seed_running_fs_pod("fs.bbbb")
    make_log_dashboard(INVITE)
    seed_logs("fs.aaaa", [[5, "INVITE a"], [4, "INVITE b"]])
    seed_logs("fs.bbbb", [[3, "INVITE c"]])

    LogMetricsSyncIslandJob.perform_now(@island.id)

    assert_equal 3, count_for(INVITE)
  end

  test "backfills deep history older than the live window" do
    seed_running_fs_pod("fs.aaaa")
    make_log_dashboard(INVITE)
    # 30 min ago is outside the 10-min recompute window → only the backfill
    # phase can capture it (within the 2-day retention).
    seed_logs("fs.aaaa", [[30 * 60, "INVITE old"], [5, "INVITE recent"]])

    LogMetricsSyncIslandJob.perform_now(@island.id)

    assert_equal 2, count_for(INVITE), "deep-history backfill + live window together"
  end

  test "lines from a pod outside the workload are not counted" do
    seed_running_fs_pod("fs.aaaa")
    seed_running_pod("other.cccc", scope: "other", resource: "other")
    make_log_dashboard(INVITE)
    seed_logs("fs.aaaa", [[5, "INVITE here"]])
    seed_logs("other.cccc", [[5, "INVITE elsewhere"]])

    LogMetricsSyncIslandJob.perform_now(@island.id)

    assert_equal 1, count_for(INVITE), "only the fs workload's INVITE counts"
  end

  test "no log panels → fast no-op, writes nothing and does not raise" do
    seed_running_fs_pod("fs.aaaa")
    seed_logs("fs.aaaa", [[5, "INVITE a"]])

    assert_nothing_raised { LogMetricsSyncIslandJob.perform_now(@island.id) }
    assert_equal 0, MetricSample.where(tenant_id: @island.id, source: "log").count
  end

  private

  def count_for(query)
    key = LogMetric::Definition.key_for(scope: "fs", name: "fs", query: query)

    MetricSample.where(tenant_id: @island.id, source: "log", name: key)
      .sum { |s| s.payload_json["log_count"].to_i }
  end

  def make_log_dashboard(query, scope: "fs", name: "fs")
    panel = {"scope_kind" => "log", "scope" => scope, "name" => name, "query" => query,
             "label" => "#{name} · count", "color" => "var(--voodu-orange)", "chart_type" => "number"}

    @island.metric_dashboards.create!(name: "d-#{SecureRandom.hex(4)}", panels: [panel])
  end

  def seed_running_fs_pod(container)
    seed_running_pod(container, scope: "fs", resource: "fs")
  end

  def seed_running_pod(container, scope:, resource:)
    @island.pods.create!(
      container_name: container, kind: "deployment", scope: scope,
      resource_name: resource, replica_id: container.split(".").last, synced_at: Time.current,
      payload: {
        "name" => container, "scope" => scope, "resource_name" => resource,
        "replica_id" => container.split(".").last, "kind" => "deployment",
        "status" => "running", "image" => "freeswitch:1"
      }.to_json
    )
  end

  # seed_logs — entries are [seconds_ago, msg]; written into the NDJSON
  # warehouse exactly as LogTail::Writer emits.
  def seed_logs(pod, entries)
    entries.each do |ago, msg|
      time = Time.current - ago
      path = LogTail::FilePath.daily_file(@island.id, pod, time.to_date)
      LogTail::FilePath.ensure_dir(File.dirname(path))
      row = {ts: time.iso8601(3), pod: pod, stream: "stdout", level: nil, msg: msg, raw: msg, parsed: false}
      File.open(path, "a") { |f| f.write("#{JSON.generate(row)}\n") }
    end
  end

  def clear_island_logs
    dir = LogTail::FilePath.island_dir(@island.id)
    FileUtils.rm_rf(dir) if Dir.exist?(dir)
  end
end
