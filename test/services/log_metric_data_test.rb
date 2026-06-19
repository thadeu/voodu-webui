# frozen_string_literal: true

require "test_helper"

# Exercises LogMetricData against a hand-seeded NDJSON warehouse on disk
# (storage/logs/<island_id>/<pod>/…), the same layout LogTail::Writer
# produces and LogSearchDataTest seeds. We assert the count semantics: the
# LogQuery filter, the dashboard-range window, aggregation across replicas,
# the retention clamp, and the COUNT_CAP floor.
#
# Time is pinned just after the seeded era so the retention floor in #window
# stays relative to the test's own clock (see LogSearchDataTest for the
# rationale on the time-bomb this avoids).
class LogMetricDataTest < ActiveSupport::TestCase
  fixtures :islands

  setup do
    @island = islands(:alpha)
    @base = Time.zone.local(2026, 6, 9, 14, 47, 50)
    travel_to @base + 1.minute
    clear_island_logs
    MetricSample.where(tenant_id: @island.id).delete_all
  end

  teardown do
    clear_island_logs
    MetricSample.where(tenant_id: @island.id).delete_all
  end

  test "counts lines matching a LogQuery regex filter over the range" do
    seed("fs.aaaa", [
      [@base, "INVITE sip:1001@host"],
      [@base + 1.second, "200 OK"],
      [@base + 2.seconds, "INVITE sip:1002@host"],
      [@base + 3.seconds, "BYE sip:1001@host"]
    ])

    data = LogMetricData.new(@island, query: "@message like /INVITE/", range: "1h", pods: ["fs.aaaa"])

    assert_equal 2, data.value
    assert_equal "2", data.formatted
    assert_not data.truncated?
    assert_not data.clamped?
  end

  test "a bare word filter degrades to a case-insensitive substring (LogQuery fallback)" do
    seed("fs.aaaa", [
      [@base, "got INVITE here"],
      [@base + 1.second, "lowercase invite too"],
      [@base + 2.seconds, "unrelated"]
    ])

    data = LogMetricData.new(@island, query: "INVITE", range: "1h", pods: ["fs.aaaa"])

    assert_equal 2, data.value, "bare word matches both cases via the substring fallback"
  end

  test "aggregates matches across every replica of the workload" do
    seed("fs.aaaa", [[@base, "INVITE one"], [@base + 1.second, "INVITE two"]])
    seed("fs.bbbb", [[@base, "INVITE three"]])
    seed("other.cccc", [[@base, "INVITE elsewhere"]])

    data = LogMetricData.new(@island, query: "@message like /INVITE/", range: "1h", pods: %w[fs.aaaa fs.bbbb])

    assert_equal 3, data.value, "both fs replicas counted, the unrelated pod excluded"
  end

  test "the window honours the dashboard range (5m excludes older matches)" do
    seed("fs.aaaa", [
      [@base - 10.minutes, "INVITE old"],
      [@base, "INVITE recent"]
    ])

    # now = @base + 1.minute → a 5m window starts at @base − 4m, so the
    # 10-minutes-ago line falls outside it.
    data = LogMetricData.new(@island, query: "@message like /INVITE/", range: "5m", pods: ["fs.aaaa"])

    assert_equal 1, data.value
  end

  test "a range past retention clamps to the retention floor and flags clamped?" do
    seed("fs.aaaa", [[@base, "INVITE recent"]])

    data = LogMetricData.new(@island, query: "@message like /INVITE/", range: "30d", pods: ["fs.aaaa"])

    assert data.clamped?, "30d outruns the 2-day retention floor"
    assert_equal 1, data.value, "still counts what's on disk within retention"
  end

  test "empty replica set counts zero without scanning" do
    seed("fs.aaaa", [[@base, "INVITE one"]])

    data = LogMetricData.new(@island, query: "@message like /INVITE/", range: "1h", pods: [])

    assert_equal 0, data.value
    assert_not data.truncated?
  end

  test "a blank query counts zero (never counts everything)" do
    seed("fs.aaaa", [[@base, "anything"], [@base + 1.second, "more"]])

    data = LogMetricData.new(@island, query: "", range: "1h", pods: ["fs.aaaa"])

    assert_equal 0, data.value
  end

  test "truncated? floors the count at COUNT_CAP" do
    with_count_cap(3) do
      seed("fs.aaaa", (0..9).map { |i| [@base + i.seconds, "INVITE #{i}"] })

      data = LogMetricData.new(@island, query: "@message like /INVITE/", range: "1h", pods: ["fs.aaaa"])

      assert_equal 3, data.value, "scan stops at the cap"
      assert data.truncated?, "value is a floor — there are more matches"
    end
  end

  test "@level filtering works through the same DSL" do
    seed_rich("fs.aaaa", [
      [@base, "boom", "ERROR"],
      [@base + 1.second, "ok", "INFO"],
      [@base + 2.seconds, "kaboom", "ERROR"]
    ])

    data = LogMetricData.new(@island, query: '@level = "ERROR"', range: "1h", pods: ["fs.aaaa"])

    assert_equal 2, data.value
  end

  # ── Fase 2: warehouse read path (pre-aggregated samples) ──────────────────

  test "reads the pre-aggregated warehouse series when the def is tracked" do
    key = LogMetric::Definition.key_for(scope: "fs", name: "fs", query: "@message like /INVITE/")
    seed_log_samples(key, [[@base - 2.minutes, 3], [@base - 1.minute, 2]])

    data = LogMetricData.new(@island, query: "@message like /INVITE/", range: "1h", scope: "fs", name: "fs", pods: ["fs.aaaa"])

    assert_equal 5, data.value, "sum of the warehouse buckets"
    assert data.series.any?, "history series is exposed for the sparkline"
    assert_equal "5", data.formatted
  end

  test "a tracked def with no matches in range reads a true 0 (not a fallback)" do
    key = LogMetric::Definition.key_for(scope: "fs", name: "fs", query: "@message like /INVITE/")
    # Tracked (a sample exists), but it's older than the 5m range window.
    seed_log_samples(key, [[@base - 2.hours, 9]])
    # NDJSON that WOULD live-scan to 1 — proves we trust the warehouse, not the scan.
    seed("fs.aaaa", [[@base, "INVITE recent"]])

    data = LogMetricData.new(@island, query: "@message like /INVITE/", range: "5m", scope: "fs", name: "fs", pods: ["fs.aaaa"])

    assert_equal 0, data.value, "warehouse has no buckets in the 5m window → true 0"
  end

  test "falls back to the live scan when the def is not yet tracked" do
    seed("fs.aaaa", [[@base, "INVITE a"], [@base + 1.second, "INVITE b"]])

    data = LogMetricData.new(@island, query: "@message like /INVITE/", range: "1h", scope: "fs", name: "fs", pods: ["fs.aaaa"])

    assert_equal 2, data.value, "no warehouse samples → live scan counts the NDJSON"
    assert_empty data.series, "fallback has no history → no sparkline"
  end

  private

  def seed_log_samples(key, buckets)
    rows = buckets.map do |time, n|
      iso = "#{time.utc.iso8601[0, 16]}:00Z"

      {tenant_id: @island.id, source: "log", ts_iso: iso,
       payload: {source: "log", ts: iso, name: key, log_count: n}.to_json}
    end

    MetricSample.bulk_insert(rows)
  end

  def with_count_cap(cap)
    original = LogMetricData::COUNT_CAP
    LogMetricData.send(:remove_const, :COUNT_CAP)
    LogMetricData.const_set(:COUNT_CAP, cap)
    yield
  ensure
    LogMetricData.send(:remove_const, :COUNT_CAP)
    LogMetricData.const_set(:COUNT_CAP, original)
  end

  # seed — plain msg lines (level nil), the common case.
  def seed(pod, lines)
    seed_rich(pod, lines.map { |time, msg| [time, msg, nil] })
  end

  # seed_rich — lines with an explicit level, in the on-disk shape
  # LogTail::Writer emits.
  def seed_rich(pod, lines)
    lines.each do |time, msg, level|
      path = LogTail::FilePath.daily_file(@island.id, pod, time.to_date)
      LogTail::FilePath.ensure_dir(File.dirname(path))
      row = {ts: time.iso8601(3), pod: pod, stream: "stdout", level: level, msg: msg, raw: msg, parsed: false}
      File.open(path, "a") { |f| f.write("#{JSON.generate(row)}\n") }
    end
  end

  def clear_island_logs
    dir = LogTail::FilePath.island_dir(@island.id)
    FileUtils.rm_rf(dir) if Dir.exist?(dir)
  end
end
