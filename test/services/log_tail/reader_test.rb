# frozen_string_literal: true

require "test_helper"

# Pins LogTail::Reader's read-side ANSI scrub. A line captured WITH terminal
# colour escapes (a legacy warehouse line, ingested before LogTail::Parser
# started stripping) must come back clean on read, so the analytics table /
# surrounding modal / export never show `[m` litter. Clean lines pass through
# untouched, and only matched lines pay the scrub — not the whole scan.
class LogTail::ReaderTest < ActiveSupport::TestCase
  fixtures :orgs, :islands

  ESC = "\e"

  setup do
    @island = islands(:alpha)
    @day = Time.utc(2026, 6, 29, 12, 0, 0)
    clear_island_logs
  end

  teardown { clear_island_logs }

  test "strips ANSI colour escapes from msg and raw on read (legacy line)" do
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

  test "drops a line that was nothing but colour escapes (scrubbed to blank)" do
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
      island_id: @island.id, pods: nil,
      from: @day - 1.hour, until_: @day + 1.hour,
      content_search: nil, regex: false, limit: 100
    ) { |pod, hash| out << [pod, hash] }

    out
  end

  def seed(pod, time, msg:, raw:)
    path = LogTail::FilePath.daily_file(@island.id, pod, time.to_date)
    LogTail::FilePath.ensure_dir(File.dirname(path))
    row = {ts: time.iso8601(3), pod: pod, stream: "stdout", level: nil, msg: msg, raw: raw, parsed: false}
    File.open(path, "a") { |f| f.write("#{JSON.generate(row)}\n") }
  end

  def clear_island_logs
    dir = LogTail::FilePath.island_dir(@island.id)
    FileUtils.rm_rf(dir) if Dir.exist?(dir)
  end
end
