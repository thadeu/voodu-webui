# frozen_string_literal: true

require "test_helper"

# Exercises LogSearchData + LogSurroundingData against a hand-seeded
# NDJSON warehouse on disk (storage/logs/<server_id>/<pod>/…), the
# same layout LogTail::Writer produces. We seed a deterministic set of
# lines, then assert the query-shaping logic: time filtering, newest-
# first ordering, full-text + regex search, pod scope, and the
# surrounding window + anchor location.
#
# Files are written under the real storage root (LogTail::FilePath has
# no test override) and torn down per-test, scoped to the fixture
# server's id so we never touch another server's tree.
class LogSearchDataTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @base = Time.zone.local(2026, 6, 9, 14, 47, 50)

    # Pin "now" to just after the seeded era. LogSearchData#window clamps
    # `from` to a retention floor relative to Time.current
    # (RETENTION_DAYS.ago); with a fixed @base and a real wall clock, that
    # floor eventually marches PAST the seeded lines and the window
    # collapses to empty (every search returns 0). Traveling time makes
    # the floor relative to the test's own era, killing the time-bomb so
    # these assertions hold no matter when they run. Auto-reset at
    # teardown via ActiveSupport::Testing::TimeHelpers.
    travel_to @base + 1.minute

    clear_server_logs
  end

  teardown { clear_server_logs }

  test "filters by time window and returns newest-first" do
    seed("web", [
      [@base, "first"],
      [@base + 1.second, "second"],
      [@base + 2.seconds, "third"],
      [@base + 3.seconds, "fourth"]
    ])

    data = search(from: iso(@base - 1.second), until: iso(@base + 2.seconds))

    msgs = data.rows.map { |r| r[:msg] }
    assert_equal %w[third second first], msgs, "newest-first, fourth excluded by until"
    assert_equal 3, data.matched
    assert_not data.truncated?
  end

  test "full-text search is a case-insensitive substring match" do
    seed("web", [
      [@base, "GET /health 200"],
      [@base + 1.second, "callid=8342416038 finished"],
      [@base + 2.seconds, "GET /metrics 200"]
    ])

    data = search(from: iso(@base - 1.second), until: iso(@base + 10.seconds), q: "CALLID")

    assert_equal 1, data.matched
    assert_equal "callid=8342416038 finished", data.rows.first[:msg]
  end

  test "| limit caps the result set to the newest N (matched stays honest)" do
    seed("web", [
      [@base, "line one"],
      [@base + 1.second, "line two"],
      [@base + 2.seconds, "line three"],
      [@base + 3.seconds, "line four"]
    ])

    data = search(from: iso(@base - 1.second), until: iso(@base + 10.seconds),
      q: "@message like /line/ | limit 2")

    assert_equal 2, data.query_limit
    assert_equal 4, data.matched, "all four matched the filter"
    assert_equal ["line four", "line three"], data.rows.map { |r| r[:msg] }, "newest 2, newest-first"
    assert_not data.has_more?, "the limit is the ceiling — no Load more past it"
  end

  test "regex search matches against the message body" do
    seed("web", [
      [@base, "status=200"],
      [@base + 1.second, "status=500"],
      [@base + 2.seconds, "status=502"]
    ])

    data = search(from: iso(@base - 1.second), until: iso(@base + 10.seconds), q: "status=5\\d2", regex: "1")

    assert_equal 1, data.matched
    assert_equal "status=502", data.rows.first[:msg]
  end

  test "pod scope restricts to the requested pod" do
    seed("web", [[@base, "from web"]])
    seed("worker", [[@base, "from worker"]])

    data = search(from: iso(@base - 1.second), until: iso(@base + 10.seconds), pods: ["worker"])

    assert_equal 1, data.matched
    assert_equal "from worker", data.rows.first[:msg]
  end

  test "multi-pod scope scans exactly the requested pods" do
    seed("web", [[@base, "from web"]])
    seed("worker", [[@base, "from worker"]])
    seed("api", [[@base, "from api"]])

    data = search(from: iso(@base - 1.second), until: iso(@base + 10.seconds), pods: %w[web worker])

    assert_equal 2, data.matched
    msgs = data.rows.map { |r| r[:msg] }
    assert_includes msgs, "from web"
    assert_includes msgs, "from worker"
    assert_not_includes msgs, "from api"
  end

  test "no pod scope scans every pod on disk" do
    seed("web", [[@base, "from web"]])
    seed("worker", [[@base, "from worker"]])

    data = search(from: iso(@base - 1.second), until: iso(@base + 10.seconds))

    assert_equal 2, data.matched
    assert data.all_pods?
  end

  test "range falls back to the default when unknown" do
    data = LogSearchData.new(server: @server, params: {range: "bogus"})
    assert_equal LogSearchData::DEFAULT_RANGE, data.range
    assert_not data.custom?
  end

  test "explicit from/until without a preset reads as custom" do
    data = LogSearchData.new(server: @server, params: {from: iso(@base), until: iso(@base + 1.minute)})
    assert data.custom?
    assert_equal "custom", data.range
  end

  test "range=custom stays custom even when from is blank (no silent preset fallback)" do
    data = LogSearchData.new(server: @server, params: {range: "custom", from: "", until: ""})
    assert data.custom?, "custom must be sticky so the inputs do not vanish on reload"
    assert_equal "custom", data.range
    # Window must resolve without a nil-comparison crash; blank from
    # defaults to one hour before until.
    assert data.from <= data.until_
    assert_in_delta 3600, (data.until_ - data.from), 5
  end

  test "from_iso / until_iso are unambiguous UTC strings" do
    data = LogSearchData.new(server: @server, params: {range: "1h"})
    assert_match(/Z\z/, data.from_iso)
    assert_match(/Z\z/, data.until_iso)
  end

  test "pages the newest-first result set by PAGE_SIZE" do
    with_page_size(5) do
      seed("web", (0..11).map { |i| [@base + i.seconds, "line-#{i}"] })
      window = {range: "custom", from: iso(@base - 1.second), until: iso(@base + 30.seconds)}

      p1 = search(window.merge(page: 1))
      assert_equal 5, p1.rows.size
      assert_equal "line-11", p1.rows.first[:msg], "page 1 starts at the newest"
      assert p1.has_more?
      assert_equal 7, p1.remaining

      p2 = search(window.merge(page: 2))
      assert_equal 5, p2.rows.size
      assert p2.has_more?

      p3 = search(window.merge(page: 3))
      assert_equal 2, p3.rows.size, "last page holds the remainder"
      assert_not p3.has_more?
      assert_equal "line-0", p3.rows.last[:msg], "oldest line lands at the very end"
    end
  end

  test "single page when matched fits under PAGE_SIZE" do
    seed("web", [[@base, "only"]])
    data = search(range: "custom", from: iso(@base - 1.second), until: iso(@base + 10.seconds))

    assert_not data.has_more?
    assert_not data.capped?
    assert_equal 1, data.page
  end

  test "surrounding keeps before/after context around the anchor" do
    lines = (0..10).map { |i| [@base + i.seconds, "line-#{i}"] }
    seed("web", lines)

    sur = LogSurroundingData.new(
      server: @server, pod: "web", ts: iso(@base + 5.seconds), before: 2, after: 2
    )

    assert sur.found?
    assert_equal 5, sur.rows.size
    assert_equal "line-5", sur.rows[sur.anchor_index][:msg]
    assert_equal %w[line-3 line-4 line-5 line-6 line-7], sur.rows.map { |r| r[:msg] },
      "oldest-first (chronological), so a trace reads top-to-bottom"
  end

  test "surrounding clamps context at the window edges" do
    lines = (0..4).map { |i| [@base + i.seconds, "line-#{i}"] }
    seed("web", lines)

    sur = LogSurroundingData.new(
      server: @server, pod: "web", ts: iso(@base), before: 100, after: 100
    )

    assert sur.found?
    assert_equal "line-0", sur.rows[sur.anchor_index][:msg]
    assert_equal 0, sur.anchor_index, "anchor is the oldest line; oldest-first puts it at the top"
    assert_equal 5, sur.rows.size
  end

  test "surrounding signals more? when the slice is cut, not when the window fits" do
    seed("web", (0..10).map { |i| [@base + i.seconds, "line-#{i}"] })

    cut = LogSurroundingData.new(server: @server, pod: "web", ts: iso(@base + 5.seconds), before: 2, after: 2)
    assert_equal 5, cut.rows.size
    assert cut.more?, "11 scanned > 5 shown → there is more to reveal"
    assert_equal 1, cut.next_expand

    full = LogSurroundingData.new(server: @server, pod: "web", ts: iso(@base + 5.seconds), before: 100, after: 100)
    assert_equal 11, full.rows.size
    assert_not full.more?, "the whole window is shown → nothing more"
  end

  test "surrounding reports not-found when the anchor is gone" do
    seed("web", [[@base, "only-line"]])

    sur = LogSurroundingData.new(
      server: @server, pod: "web", ts: iso(@base + 1.hour), before: 5, after: 5
    )

    assert_not sur.found?
  end

  private

  def search(params)
    LogSearchData.new(server: @server, params: params)
  end

  # with_page_size — temporarily shrink PAGE_SIZE so pagination is
  # testable without seeding thousands of lines. Restored after.
  def with_page_size(size)
    original = LogSearchData::PAGE_SIZE
    LogSearchData.send(:remove_const, :PAGE_SIZE)
    LogSearchData.const_set(:PAGE_SIZE, size)
    yield
  ensure
    LogSearchData.send(:remove_const, :PAGE_SIZE)
    LogSearchData.const_set(:PAGE_SIZE, original)
  end

  def iso(time)
    time.iso8601(3)
  end

  # seed — write lines (each [time, msg]) into the daily NDJSON file
  # for the given pod, in the exact on-disk shape LogTail::Writer emits.
  def seed(pod, lines)
    lines.each do |time, msg|
      path = LogTail::FilePath.daily_file(@server.id, pod, time.to_date)
      LogTail::FilePath.ensure_dir(File.dirname(path))
      row = {
        ts: time.iso8601(3),
        pod: pod,
        stream: "stdout",
        level: nil,
        msg: msg,
        raw: msg,
        parsed: false
      }
      File.open(path, "a") { |f| f.write("#{JSON.generate(row)}\n") }
    end
  end

  def clear_server_logs
    dir = LogTail::FilePath.server_dir(@server.id)
    FileUtils.rm_rf(dir) if Dir.exist?(dir)
  end
end
