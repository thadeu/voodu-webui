# frozen_string_literal: true

require "test_helper"

# Pins the watermark-advance contract in LogTailServerJob#poll_once after
# the dedup fix made the watermark persist across runs. Two regressions
# the persisted watermark could introduce (and that this guards against):
#
#   1. Advancing the watermark past a line the Writer DROPPED (disk
#      pressure / cap) → the next run's `since` skips it forever.
#   2. An inclusive `ts <= watermark` boundary guard dropping a DISTINCT
#      line that shares the watermark's exact millisecond.
class LogTailServerJobTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  WATERMARK = "2026-06-09T12:00:00.000Z"

  # FakeClient yields canned chunks to the block, like the real
  # Voodu::Client#logs_stream_multi (which streams docker log bytes).
  class FakeClient
    def initialize(chunks) = (@chunks = chunks)

    def logs_stream_multi(**_opts, &block)
      @chunks.each(&block)
    end
  end

  setup do
    @server = servers(:alpha)
    clear_server_logs
  end

  teardown { clear_server_logs }

  test "watermark does not advance past a line the Writer dropped (disk pressure)" do
    Time.use_zone("UTC") do
      writer = LogTail::Writer.new(@server.id)
      writer.instance_variable_set(:@disk_ok, false) # simulate disk-pressure pause

      advanced = :unset
      count = poll_once(FakeClient.new([line(at: "2026-06-09T12:05:00.000Z")]), writer, WATERMARK) { |ts| advanced = ts }

      assert_equal :unset, advanced, "must not advance the watermark when nothing was persisted"
      assert_equal 0, count
    end
  end

  test "watermark advances for a persisted line" do
    Time.use_zone("UTC") do
      writer = LogTail::Writer.new(@server.id)

      advanced = nil
      count = poll_once(FakeClient.new([line(at: "2026-06-09T12:05:00.000Z")]), writer, WATERMARK) { |ts| advanced = ts }
      writer.close

      assert_equal 1, count
      assert advanced, "watermark should advance for a written line"
      assert Time.zone.parse(advanced) > Time.zone.parse(WATERMARK)
    end
  end

  test "a distinct line sharing the watermark ms is kept (strict boundary guard)" do
    Time.use_zone("UTC") do
      writer = LogTail::Writer.new(@server.id)

      count = poll_once(FakeClient.new([line(at: WATERMARK, msg: "boundary")]), writer, WATERMARK) { |_ts| }
      writer.close

      assert_equal 1, count, "a distinct line at the exact watermark ms must still be persisted"
    end
  end

  private

  def poll_once(client, writer, watermark, &block)
    LogTailServerJob.new.send(:poll_once, client, writer, watermark, &block)
  end

  def line(at:, msg: "hello")
    %([web] {"time":"#{at}","msg":"#{msg}"}\n)
  end

  def clear_server_logs
    dir = LogTail::FilePath.server_dir(@server.id)
    FileUtils.rm_rf(dir) if Dir.exist?(dir)
  end
end
