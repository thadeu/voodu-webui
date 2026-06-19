# frozen_string_literal: true

require "test_helper"

# Runs in warehouse mode so MetricsData reads the local metrics SQLite
# instead of needing a live controller — same headless pattern as
# IslandUptimeTest. We don't assert metric VALUES (the warehouse is
# empty here, charts come back flat); we assert the dashboard-specific
# logic: workload→replica resolution, the missing placeholder, and the
# range/interval guards.
class MetricDashboardDataTest < ActiveSupport::TestCase
  fixtures :islands

  setup do
    @island = islands(:alpha)
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"
  end

  teardown do
    ENV["WAREHOUSE"] = @prev_wh
    dir = LogTail::FilePath.island_dir(@island.id)
    FileUtils.rm_rf(dir) if Dir.exist?(dir)
  end

  HOST = {
    "scope_kind" => "host", "metric" => "cpu_percent", "scale" => "percent",
    "label" => "CPU", "color" => "var(--voodu-accent)", "unit" => "%"
  }.freeze

  WEB_MEM = {
    "scope_kind" => "pod", "scope" => "web", "name" => "web", "kind" => "deployment",
    "metric" => "mem_usage_bytes", "scale" => "bytes_to_mb",
    "label" => "web · Memory", "color" => "var(--voodu-blue)", "unit" => "MB"
  }.freeze

  test "host panel always renders; pod panel resolves to the running replica" do
    seed_running_web_pod
    dash = make_dashboard([HOST, WEB_MEM])

    charts = MetricDashboardData.new(client, @island, dash, range: "1h").charts

    assert_equal 2, charts.size
    assert_equal "CPU", charts[0][:label]
    assert_not charts[0][:missing]

    assert_not charts[1][:missing]
    assert_equal "web.aaaa", charts[1][:scope_id]
    assert_equal "pod", charts[1][:scope_kind]
  end

  test "pod panel becomes a missing placeholder when no replica is running" do
    dash = make_dashboard([HOST, WEB_MEM])

    charts = MetricDashboardData.new(client, @island, dash, range: "1h").charts

    assert_equal 2, charts.size
    assert_not charts[0][:missing], "host panel should still render"
    assert charts[1][:missing], "pod panel with no replica should be missing"
    assert_equal "web", charts[1][:source_label]
  end

  FS_CALLS = {
    "scope_kind" => "log", "scope" => "fs", "name" => "fs",
    "query" => "@message like /INVITE/", "agg" => "count",
    "label" => "fs · INVITE", "color" => "var(--voodu-orange)", "chart_type" => "number"
  }.freeze

  test "log panel reads the pre-aggregated count series into a number envelope" do
    dash = make_dashboard([FS_CALLS])
    seed_log_samples(FS_CALLS["query"], [[5, 7], [1, 3]]) # latest bucket = 3 (count)

    charts = MetricDashboardData.new(client, @island, dash, range: "1h").charts

    assert_equal 1, charts.size
    c = charts.first
    assert_equal :number, c[:kind]
    assert_equal 3, c[:value], "count = latest bucket"
    assert_equal "fs · INVITE", c[:label]
    assert_equal "1h", c[:range]
    assert_equal "k0", c[:panel_key]
    assert c[:series].any?, "series for the sparkline"
    assert c[:default_visible]
  end

  test "log panel with no counted data yet reads zero" do
    dash = make_dashboard([FS_CALLS])

    c = MetricDashboardData.new(client, @island, dash, range: "1h").charts.first

    assert_equal :number, c[:kind]
    assert_equal 0, c[:value]
  end

  test "invalid range/interval fall back to defaults; range_ms derived" do
    dash = make_dashboard([HOST])
    data = MetricDashboardData.new(client, @island, dash, range: "zzz", interval: "bogus")

    assert_equal MetricsPageData::DEFAULT_RANGE, data.range
    assert_equal "auto", data.interval
    assert data.range_ms.positive?
    assert data.dashboard?
    assert_not data.empty?
  end

  private

  # A real client object (no network at construction). In warehouse
  # mode MetricsData never uses it, but MetricsPageData#single_chart
  # guards on client presence — the controller always supplies a
  # non-nil voodu_client, so the service does too.
  def client
    @client ||= Voodu::Client.new(@island)
  end

  def make_dashboard(panels)
    @island.metric_dashboards.create!(name: "d-#{panels.size}-#{panels.object_id}", panels: panels)
  end

  def seed_running_web_pod
    @island.pods.create!(
      container_name: "web.aaaa",
      kind: "deployment",
      scope: "web",
      resource_name: "web",
      replica_id: "aaaa",
      synced_at: Time.current,
      payload: {
        "name" => "web.aaaa", "scope" => "web", "resource_name" => "web",
        "replica_id" => "aaaa", "kind" => "deployment", "status" => "running",
        "image" => "nginx:1.27"
      }.to_json
    )
  end

  # seed_log_samples — write the counter's per-bucket log_count rows under the
  # query's def_key. counts: [[minutes_ago, count], ...].
  def seed_log_samples(query, counts)
    key = LogMetric::Definition.key_for(scope: "fs", name: "fs", query: query)

    rows = counts.map do |mins, n|
      iso = "#{(Time.current - mins.minutes).utc.iso8601[0, 16]}:00Z"

      {tenant_id: @island.id, source: "log", ts_iso: iso,
       payload: {source: "log", ts: iso, name: key, log_count: n}.to_json}
    end

    MetricSample.bulk_insert(rows)
  end
end
