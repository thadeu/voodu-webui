# frozen_string_literal: true

require "test_helper"

# Exercises the full request stack for /logs/analytics — these also
# smoke-render the Phlex Page / FilterBar / Results / Row / Surrounding
# components (a render error surfaces as a 500 here). WAREHOUSE mode
# keeps pod-picker resolution off the network; the log lines come from a
# hand-seeded NDJSON warehouse on disk.
class LogsAnalyticsControllerTest < ActionDispatch::IntegrationTest
  fixtures :islands

  setup do
    @island       = islands(:alpha)
    @key          = @island.key
    @base         = Time.zone.local(2026, 6, 9, 14, 47, 50)
    @prev_wh      = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"

    # Pin "now" to the seeded era so LogSearchData#window's retention-floor
    # clamp (RETENTION_DAYS.ago, relative to Time.current) stays behind the
    # fixed @base. Without this the wall clock eventually marches past the
    # seeded lines and every search returns 0 — the same time-bomb that hit
    # LogSearchDataTest. Auto-reset at teardown by TimeHelpers.
    travel_to @base + 1.minute

    clear_island_logs
  end

  teardown do
    ENV["WAREHOUSE"] = @prev_wh
    clear_island_logs
  end

  test "index renders the analytics page with the filter bar" do
    get logs_analytics_path(tenant_key: @key)

    assert_response :success
    assert_match "Log search", @response.body
    assert_match 'data-controller="log-analytics"', @response.body
    assert_match "logs-analytics-results", @response.body
  end

  test "frame request renders only the results table and applies the search" do
    seed("web", [
      [@base,             "GET /health 200"],
      [@base + 1.second,  "callid=8342416038 finished"]
    ])

    get logs_analytics_path(tenant_key: @key),
        params:  { range: "custom", from: iso(@base - 1.second), until: iso(@base + 10.seconds), q: "callid" },
        headers: { "Turbo-Frame" => "logs-analytics-results" }

    assert_response :success
    assert_match "callid=8342416038 finished", @response.body
    assert_no_match "GET /health 200", @response.body
    assert_match "matched", @response.body
    assert_match "Jump to bottom", @response.body, "jump controls render with results"
  end

  test "empty result set renders the empty state" do
    get logs_analytics_path(tenant_key: @key),
        params:  { range: "custom", from: iso(@base), until: iso(@base + 1.second), q: "nothing-matches-this" },
        headers: { "Turbo-Frame" => "logs-analytics-results" }

    assert_response :success
    assert_match "No log lines match this query", @response.body
  end

  test "load-more frame returns the next page wrapped in its la-page frame" do
    with_page_size(3) do
      seed("web", (0..6).map { |i| [@base + i.seconds, "line-#{i}"] })

      get logs_analytics_path(tenant_key: @key),
          params:  { range: "custom", from: iso(@base - 1.second), until: iso(@base + 30.seconds), page: 2 },
          headers: { "Turbo-Frame" => "la-page-2" }

      assert_response :success
      assert_match 'id="la-page-2"', @response.body, "wrapped in the requested frame"
      assert_match "line-", @response.body, "renders the page-2 rows"
      assert_match "la-page-3", @response.body, "offers the next-page trigger"
    end
  end

  test "export streams the current query as a download, applying filters" do
    seed("web", [
      [@base,             "GET /health 200"],
      [@base + 1.second,  "callid=8342416038 finished"]
    ])
    window = { from: iso(@base - 1.second), until: iso(@base + 10.seconds), q: "callid" }

    # NDJSON — full records, only the matching line, as an attachment.
    get logs_analytics_export_path(tenant_key: @key), params: window.merge(fmt: "ndjson")
    assert_response :success
    assert_match %r{application/x-ndjson}, @response.media_type
    assert_match(/attachment; filename=.*\.ndjson/, @response.headers["Content-Disposition"])
    assert_match "callid=8342416038 finished", @response.body
    assert_no_match "GET /health 200", @response.body

    # CSV — column header present.
    get logs_analytics_export_path(tenant_key: @key), params: window.merge(fmt: "csv")
    assert_response :success
    assert_match "text/csv", @response.media_type
    assert @response.body.start_with?("ts,pod,stream,level,msg\n"), "csv header"

    # JSON — a parseable array of the matched rows.
    get logs_analytics_export_path(tenant_key: @key), params: window.merge(fmt: "json")
    assert_response :success
    rows = JSON.parse(@response.body)
    assert_equal 1, rows.size
    assert_equal "callid=8342416038 finished", rows.first["msg"]
    assert_match(/\[\n\s+\{/, @response.body, "Copy JSON is pretty-printed, not inline")
  end

  test "surrounding exports the shown batch as a download" do
    seed("web", (0..6).map { |i| [@base + i.seconds, "line-#{i}"] })

    get logs_analytics_surrounding_path(tenant_key: @key),
        params: { pod: "web", ts: iso(@base + 3.seconds), fmt: "csv" }

    assert_response :success
    assert_match "text/csv", @response.media_type
    assert_match(/attachment; filename=.*surrounding.*\.csv/, @response.headers["Content-Disposition"])
    assert @response.body.start_with?("ts,pod,stream,level,msg\n"), "csv header"
    assert_match "line-3", @response.body
  end

  test "surrounding renders the modal anchored on the selected line" do
    lines = (0..6).map { |i| [@base + i.seconds, "line-#{i}"] }
    seed("web", lines)

    get logs_analytics_surrounding_path(tenant_key: @key),
        params: { pod: "web", ts: iso(@base + 3.seconds), before: 2, after: 2 }

    assert_response :success
    assert_match "Surrounding logs", @response.body
    assert_match 'data-controller="modal"', @response.body
    assert_match "data-surrounding-anchor", @response.body
    assert_match "line-3", @response.body
  end

  private

  def iso(time)
    time.iso8601(3)
  end

  def seed(pod, lines)
    lines.each do |time, msg|
      path = LogTail::FilePath.daily_file(@island.id, pod, time.to_date)
      LogTail::FilePath.ensure_dir(File.dirname(path))
      row = { ts: time.iso8601(3), pod: pod, stream: "stdout", level: nil, msg: msg, raw: msg, parsed: false }
      File.open(path, "a") { |f| f.write("#{JSON.generate(row)}\n") }
    end
  end

  def clear_island_logs
    dir = LogTail::FilePath.island_dir(@island.id)
    FileUtils.rm_rf(dir) if Dir.exist?(dir)
  end

  def with_page_size(size)
    original = LogSearchData::PAGE_SIZE
    LogSearchData.send(:remove_const, :PAGE_SIZE)
    LogSearchData.const_set(:PAGE_SIZE, size)
    yield
  ensure
    LogSearchData.send(:remove_const, :PAGE_SIZE)
    LogSearchData.const_set(:PAGE_SIZE, original)
  end
end
