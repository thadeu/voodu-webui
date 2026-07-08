# frozen_string_literal: true

require "test_helper"

# Runs in warehouse mode so MetricsData reads the local metrics SQLite
# instead of needing a live controller — same headless pattern as
# ServerUptimeTest. We don't assert metric VALUES (the warehouse is
# empty here, charts come back flat); we assert the dashboard-specific
# logic: workload→replica resolution, the missing placeholder, and the
# range/interval guards.
class MetricDashboardDataTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @org = @server.org
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"
  end

  teardown do
    ENV["WAREHOUSE"] = @prev_wh
    dir = LogTail::FilePath.server_dir(@server.id)
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

    charts = MetricDashboardData.new(@org, dash, range: "1h").charts

    assert_equal 2, charts.size
    assert_equal "CPU", charts[0][:label]
    assert_not charts[0][:missing]

    assert_not charts[1][:missing]
    assert_equal "web.aaaa", charts[1][:scope_id]
    assert_equal "pod", charts[1][:scope_kind]
  end

  # A multi-series can mix the Host with pods: one line for the host (node
  # metrics, no container) + one per pod. The panel anchors on the host but still
  # routes to the multi-series builder, yielding one series per member.
  test "a host + pod line panel builds one series per member (host labeled 'host')" do
    seed_running_web_pod

    panel = {"scope_kind" => "host", "metric" => "cpu_percent", "scale" => "percent",
             "label" => "Host+web CPU", "color" => "var(--voodu-purple)", "unit" => "%",
             "chart_type" => "line", "server_id" => @server.id,
             "pods" => [{"scope_kind" => "host", "server_id" => @server.id},
               {"scope_kind" => "pod", "server_id" => @server.id, "scope" => "web", "name" => "web", "kind" => "deployment"}]}
    dash = @org.metric_dashboards.create!(name: "hp", panels: [panel])

    c = MetricDashboardData.new(@org, dash, range: "1h").charts.first

    assert c[:multi], "host + pod line → a multi-series envelope"
    assert_equal 2, c[:series].size, "one series per member (host + web pod)"
    # This org has >1 server (fixtures), so labels carry the "<server> · " prefix
    # to disambiguate — a bare "host" is ambiguous across N servers.
    assert_equal ["#{@server.name} · host", "#{@server.name} · web"], c[:series].map { |s| s[:label] }.sort,
      "host member labeled '<server> · host' in a multi-server org"
  end

  # chart_at — the maximize modal's single-panel entry (a multi chart references
  # its dashboard + index). Returns that panel's chart, nil for an out-of-range
  # index.
  test "chart_at returns one panel's chart by index, nil out of range" do
    dash = make_dashboard([HOST])
    data = MetricDashboardData.new(@org, dash, range: "1h")

    assert_equal "cpu_percent", data.chart_at(0)[:metric]
    assert_nil data.chart_at(9)
  end

  test "a panel forged to read a server in ANOTHER org resolves to a placeholder, never a cross-org read" do
    # gamma lives in globex, NOT @org (acme). A panel whose server_id points at
    # it must NOT resolve — the read-path only resolves servers WITHIN @org
    # (servers_by_id is org-scoped), so a forged/cross-org id is a dead panel.
    gamma = servers(:gamma)
    assert_not_equal @org.id, gamma.org_id, "gamma must be in a different org for this to test isolation"

    forged = HOST.merge("server_id" => gamma.id, "label" => "forged")
    dash = @org.metric_dashboards.new(name: "forged", panels: [forged])

    charts = MetricDashboardData.new(@org, dash, range: "1h").charts

    assert_equal 1, charts.size
    assert charts[0][:missing], "a cross-org panel must be a missing placeholder, never a cross-org read"
  end

  test "pod panel becomes a missing placeholder when no replica is running" do
    dash = make_dashboard([HOST, WEB_MEM])

    charts = MetricDashboardData.new(@org, dash, range: "1h").charts

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

    charts = MetricDashboardData.new(@org, dash, range: "1h").charts

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

  test "log panel with show_chart false keeps the count but drops the chart series" do
    dash = make_dashboard([FS_CALLS.merge("show_chart" => false)])
    seed_log_samples(FS_CALLS["query"], [[5, 7], [1, 3]]) # same data as the chart case

    c = MetricDashboardData.new(@org, dash, range: "1h").charts.first

    assert_equal :number, c[:kind]
    assert_equal 3, c[:value], "count is still computed — only the chart is hidden"
    assert_empty c[:series], "show_chart false → no timeline series (number-only tile)"
  end

  test "log panel with show_chart true renders the chart series" do
    dash = make_dashboard([FS_CALLS.merge("show_chart" => true)])
    seed_log_samples(FS_CALLS["query"], [[5, 7], [1, 3]])

    c = MetricDashboardData.new(@org, dash, range: "1h").charts.first

    assert c[:series].any?, "show_chart true → timeline series present"
  end

  # A log-query panel can also render its count series AS A CHART (area/bars/
  # line) instead of a number — same series, chosen by chart_type. Reuses the
  # SAME pre-aggregated log_count warehouse series (no counter change).
  test "a log panel with an area chart_type renders a chart envelope, not a number" do
    dash = make_dashboard([FS_CALLS.merge("chart_type" => "area")])
    seed_log_samples(FS_CALLS["query"], [[5, 7], [1, 3]])

    c = MetricDashboardData.new(@org, dash, range: "1h").charts.first

    assert_nil c[:kind], "chart render → ChartCard (no :number kind)"
    assert_equal "area", c[:chart_type]
    assert_equal "log", c[:source], "source=log so the maximize modal rebuilds it"
    assert c[:points].any?, "count-over-time points for the chart"
  end

  # A render a measure can't fill draws EMPTY (zeroed), not a misleading fallback
  # and not an error. Product choice: the operator owns the (measure, render) pair.
  test "a host metric with a number/table render reads empty (zeroed), not an area fallback" do
    %w[number table].each do |ct|
      dash = make_dashboard([HOST.merge("chart_type" => ct)])
      c = MetricDashboardData.new(@org, dash, range: "1h").charts.first

      assert c[:zeroed], "host + #{ct} → zeroed"
      assert_empty c[:points], "a zeroed card carries no points"
      assert_nil c[:kind], "still a ChartCard envelope (empty), not a :number/:table card"
    end
  end

  test "a log-query panel with a gauge render reads empty (zeroed) — a count has no ceiling" do
    dash = make_dashboard([FS_CALLS.merge("chart_type" => "gauge_radial")])
    seed_log_samples(FS_CALLS["query"], [[5, 7], [1, 3]])

    c = MetricDashboardData.new(@org, dash, range: "1h").charts.first

    assert c[:zeroed], "log + gauge → zeroed"
    assert_empty c[:points]
    assert_nil c[:kind], "not a :number tile — the operator picked a gauge, which reads empty"
  end

  # The chart's headline (current) must equal the number tile's value for the
  # SAME filter — number and chart of one query always agree.
  test "log chart and log number of the same filter report the same headline value" do
    seed_log_samples(FS_CALLS["query"], [[5, 7], [1, 3]])

    num = MetricDashboardData.new(@org, make_dashboard([FS_CALLS]), range: "1h").charts.first
    chart = MetricDashboardData.new(@org, make_dashboard([FS_CALLS.merge("chart_type" => "line")]), range: "1h").charts.first

    assert_equal num[:value], chart[:current], "chart current == number value (parity)"
  end

  test "log panel with no counted data yet reads zero" do
    dash = make_dashboard([FS_CALLS])

    c = MetricDashboardData.new(@org, dash, range: "1h").charts.first

    assert_equal :number, c[:kind]
    assert_equal 0, c[:value]
  end

  test "custom from/until_ window bounds the log count series" do
    base = Time.zone.local(2026, 6, 19, 12, 0, 0)
    q = "@message like /INVITE/ | sum"
    dash = make_dashboard([FS_CALLS.merge("query" => q)])

    seed_log_at(q, base - 2.hours, 99)   # before the window
    seed_log_at(q, base, 5)              # inside
    seed_log_at(q, base + 5.minutes, 7)  # inside
    seed_log_at(q, base + 2.hours, 50)   # after the window

    data = MetricDashboardData.new(@org, dash, range: "1h",
      from: base - 1.minute, until_: base + 10.minutes)

    assert data.custom?, "explicit from+until → custom mode"

    c = data.charts.first
    assert_equal :number, c[:kind]
    assert_equal 12, c[:value], "sum of in-window buckets only (5 + 7)"
  end

  test "custom window with a metric panel narrows MetricsPageData's fetch" do
    base = Time.zone.local(2026, 6, 19, 12, 0, 0)
    dash = make_dashboard([HOST])

    data = MetricDashboardData.new(@org, dash, range: "1h",
      from: base - 30.minutes, until_: base)

    assert data.custom?
    assert_equal (30 * 60 * 1000), data.range_ms, "range_ms = the custom window width, not the 1h shortcut"
  end

  test "invalid range/interval fall back to defaults; range_ms derived" do
    dash = make_dashboard([HOST])
    data = MetricDashboardData.new(@org, dash, range: "zzz", interval: "bogus")

    assert_equal MetricsPageData::DEFAULT_RANGE, data.range
    assert_equal "auto", data.interval
    assert data.range_ms.positive?
    assert data.dashboard?
    assert_not data.empty?
  end

  private

  # make_dashboard — an org dashboard whose server panels bind to @server (M2:
  # every non-http panel carries its server_id; the read-path resolves each
  # panel's server WITHIN the org). http panels are external — no server_id.
  def make_dashboard(panels)
    with_server = panels.map { |p| (p["source"].to_s == "http") ? p : p.merge("server_id" => @server.id) }

    @org.metric_dashboards.create!(name: "d-#{panels.size}-#{panels.object_id}", panels: with_server)
  end

  def seed_running_web_pod
    @server.pods.create!(
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

      {server_id: @server.id, source: "log", ts_iso: iso,
       payload: {source: "log", ts: iso, name: key, log_count: n}.to_json}
    end

    MetricSample.bulk_insert(rows)
  end

  # seed_log_at — one bucket row at an absolute time (for custom-window tests).
  def seed_log_at(query, time, count)
    key = LogMetric::Definition.key_for(scope: "fs", name: "fs", query: query)
    iso = "#{time.utc.iso8601[0, 16]}:00Z"

    MetricSample.bulk_insert([
      {server_id: @server.id, source: "log", ts_iso: iso,
       payload: {source: "log", ts: iso, name: key, log_count: count}.to_json}
    ])
  end
end
