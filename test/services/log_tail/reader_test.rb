# frozen_string_literal: true

require "test_helper"

# Pins LogTail::Reader's read-side ANSI scrub. A line captured WITH terminal
# color escapes (a legacy warehouse line, ingested before LogTail::Parser
# started stripping) must come back clean on read, so the analytics table /
# surrounding modal / export never show `[m` litter. Clean lines pass through
# untouched, and only matched lines pay the scrub — not the whole scan.
class LogTail::ReaderTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  ESC = "\e"

  setup do
    @server = servers(:alpha)
    @day = Time.utc(2026, 6, 29, 12, 0, 0)
    clear_server_logs
  end

  teardown { clear_server_logs }

  test "strips ANSI color escapes from msg and raw on read (legacy line)" do
    dirty = "#{ESC}[m#{ESC}[msend 609 bytes to udp/[54.20.49.188]:5060"
    seed("fsw", @day, msg: dirty, raw: "2026-06-29T12:00:00.000Z #{dirty}")

    rows = read_all
    assert_equal 1, rows.size

    _pod, hash = rows.first
    assert_equal "send 609 bytes to udp/[54.20.49.188]:5060", hash["msg"]
    assert_not_includes hash["raw"], ESC, "no ESC byte survives the read"
    assert_not_includes hash["raw"], "[m", "no bare CSI litter survives the read"
  end

  test "a clean line passes through unchanged" do
    seed("web", @day, msg: "GET /health 200", raw: "GET /health 200")

    _pod, hash = read_all.first
    assert_equal "GET /health 200", hash["msg"]
    assert_equal "GET /health 200", hash["raw"]
  end

  test "drops orphan rows that are only a timestamp (blank source line)" do
    seed("fsw", @day, msg: "", raw: "2026-06-29T12:00:00.000000000Z ")
    seed("fsw", @day + 1.second, msg: "SIP/2.0 200 OK", raw: "2026-06-29T12:00:01.000Z SIP/2.0 200 OK")

    rows = read_all
    assert_equal 1, rows.size, "the timestamp-only orphan is dropped, the real line stays"
    assert_equal "SIP/2.0 200 OK", rows.first.last["msg"]
  end

  test "drops a line that was nothing but color escapes (scrubbed to blank)" do
    seed("fsw", @day, msg: "#{ESC}[m#{ESC}[m", raw: "2026-06-29T12:00:00.000Z #{ESC}[m#{ESC}[m")

    assert_empty read_all, "an escapes-only line has no content once scrubbed"
  end

  test "keeps a real line even when its raw carries a leading timestamp" do
    seed("fsw", @day, msg: "Content-Length: 0", raw: "2026-06-29T12:00:00.000Z Content-Length: 0")

    _pod, hash = read_all.first
    assert_equal "Content-Length: 0", hash["msg"]
  end

  private

  def read_all
    out = []
    LogTail::Reader.each_line(
      server: @server, pods: nil,
      from: @day - 1.hour, until_: @day + 1.hour,
      content_search: nil, regex: false, limit: 100
    ) { |pod, hash| out << [pod, hash] }

    out
  end

  def seed(pod, time, msg:, raw:)
    path = LogTail::FilePath.daily_file(@server, pod, time.to_date)
    LogTail::FilePath.ensure_dir(File.dirname(path))
    row = {ts: time.iso8601(3), pod: pod, stream: "stdout", level: nil, msg: msg, raw: raw, parsed: false}
    File.open(path, "a") { |f| f.write("#{JSON.generate(row)}\n") }
  end

  def clear_server_logs
    dir = LogTail::FilePath.server_dir(@server)
    FileUtils.rm_rf(dir) if Dir.exist?(dir)
  end
end

# The seek is an optimization with a correctness contract: whatever offset
# the binary search picks, the [from, until] filter must still see every
# line inside the window. These pin the boundaries the search can get wrong:
# a window deep inside a large file, a short out-of-order overlap at a write
# boundary, lines the probe cannot read, and a file that starts mid-window.
class LogTail::ReaderSeekTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @pod = "seek-web.0001"
    @day = Time.utc(2026, 6, 29, 0, 0, 0)
    clear_server_logs
  end

  teardown { clear_server_logs }

  test "a window deep inside a file well past the slack yields exactly its lines" do
    n = 40_000
    write_lines(n) { |i| @day + i }

    from = @day + 30_000
    until_ = @day + 30_099

    got = read(from, until_)

    assert_equal 100, got.size
    assert_equal from.iso8601(3), got.first["ts"]
    assert_equal until_.iso8601(3), got.last["ts"]
  end

  test "a line appended slightly out of order inside the slack is still found" do
    n = 40_000
    write_lines(n) { |i| @day + i }

    # A re-tail overlap: one older line lands after newer ones, near the end.
    late = @day + 39_000
    seed(@pod, late, msg: "late arrival")

    got = read(late, late)

    assert_equal 2, got.size, "the in-order line and the late duplicate both sit inside the window"
    assert_includes got.map { |h| h["msg"] }, "late arrival"
  end

  test "lines without a readable timestamp do not derail the search" do
    write_lines(20_000) { |i| @day + i }

    path = LogTail::FilePath.daily_file(@server, @pod, @day.to_date)
    File.open(path, "a") { |f| f.write(%({"pod":"#{@pod}","msg":"sentinel: file cap reached"}\n)) }

    from = @day + 19_990
    got = read(from, @day + 19_999)

    assert_equal 10, got.size
  end

  test "a window that starts before the file reads it from the top" do
    write_lines(20_000) { |i| @day + 3_600 + i }

    got = read(@day, @day + 3_600 + 4)

    assert_equal 5, got.size
    assert_equal (@day + 3_600).iso8601(3), got.first["ts"]
  end

  test "the scan stops at the first line past the window" do
    write_lines(20_000) { |i| @day + i }

    calls = 0
    LogTail::Reader.each_line(
      server: @server, pods: [@pod], from: @day + 100, until_: @day + 104,
      content_search: nil, regex: false, limit: 1_000_000
    ) { |_pod, _hash| calls += 1 }

    assert_equal 5, calls
  end

  private

  def read(from, until_)
    out = []
    LogTail::Reader.each_line(
      server: @server, pods: [@pod], from: from, until_: until_,
      content_search: nil, regex: false, limit: 1_000_000
    ) { |_pod, hash| out << hash }

    out
  end

  def write_lines(count)
    path = LogTail::FilePath.daily_file(@server, @pod, @day.to_date)
    LogTail::FilePath.ensure_dir(File.dirname(path))

    File.open(path, "w") do |f|
      count.times do |i|
        time = yield(i)
        row = {ts: time.iso8601(3), pod: @pod, stream: "stdout", level: nil, msg: "line #{i} padding to make the file wide enough for a real seek", raw: "line #{i}", parsed: false}
        f.write("#{JSON.generate(row)}\n")
      end
    end
  end

  def seed(pod, time, msg:)
    path = LogTail::FilePath.daily_file(@server, pod, time.to_date)
    row = {ts: time.iso8601(3), pod: pod, stream: "stdout", level: nil, msg: msg, raw: msg, parsed: false}
    File.open(path, "a") { |f| f.write("#{JSON.generate(row)}\n") }
  end

  def clear_server_logs
    dir = LogTail::FilePath.server_dir(@server)
    FileUtils.rm_rf(dir) if Dir.exist?(dir)
  end
end
