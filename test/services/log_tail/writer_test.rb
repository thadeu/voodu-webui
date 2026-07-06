# frozen_string_literal: true

require "test_helper"

# Pins the LogTail::Writer dedupe — in particular that a FRESH Writer
# (new job run / restart / watermark-lost resume) recognises lines
# already on disk and never re-appends them. This is the durable
# guarantee behind the duplicate-lines fix: regardless of why the tail
# job re-fetches an overlapping batch, byte-identical lines hit the
# warehouse at most once.
class LogTail::WriterTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    clear_server_logs
  end

  teardown { clear_server_logs }

  test "a fresh Writer dedupes against lines already on disk" do
    line = line_for("hello", ts: "2026-06-09T15:00:00.000Z")

    w1 = LogTail::Writer.new(@server.id)
    assert w1.append("web", line), "first write lands"
    w1.close

    # New Writer = empty in-memory window. It must still skip the
    # identical line by seeding its window from the file tail.
    w2 = LogTail::Writer.new(@server.id)
    assert_not w2.append("web", line), "identical on-disk line is skipped"
    assert w2.append("web", line_for("world", ts: "2026-06-09T15:00:01.000Z")), "a genuinely new line still writes"
    w2.close

    assert_equal 2, File.readlines(daily_path("web")).size, "file holds each line once"
  end

  test "dedupes within a single Writer run too" do
    line = line_for("repeat", ts: "2026-06-09T15:00:00.000Z")

    w = LogTail::Writer.new(@server.id)
    assert w.append("web", line)
    assert_not w.append("web", line), "same line twice in one run is skipped"
    w.close

    assert_equal 1, File.readlines(daily_path("web")).size
  end

  private

  def line_for(msg, ts:)
    {ts: ts, pod: "web", stream: "stdout", level: nil, msg: msg, raw: msg, parsed: false}
  end

  def daily_path(pod)
    LogTail::FilePath.daily_file(@server.id, pod, Date.current)
  end

  def clear_server_logs
    dir = LogTail::FilePath.server_dir(@server.id)
    FileUtils.rm_rf(dir) if Dir.exist?(dir)
  end
end
