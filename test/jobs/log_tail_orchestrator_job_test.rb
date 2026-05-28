# frozen_string_literal: true

require "test_helper"

class LogTailOrchestratorJobTest < ActiveJob::TestCase
  fixtures :islands

  teardown do
    ENV.delete("LOG_POLLER_SPAWN")
  end

  test "early-returns without touching Island when LOG_POLLER_SPAWN=1" do
    ENV["LOG_POLLER_SPAWN"] = "1"

    # Pin: no Island queries, no enqueues. If perform reached the
    # find_each path, the counter would increment.
    calls = 0
    Island.singleton_class.define_method(:find_each) do |*, **, &blk|
      calls += 1
      blk&.call(Island.first)
    end

    begin
      assert_no_enqueued_jobs do
        LogTailOrchestratorJob.new.perform
      end
      assert_equal 0, calls, "Island.find_each must not be called when LOG_POLLER_SPAWN=1"
    ensure
      Island.singleton_class.send(:remove_method, :find_each)
    end
  end

  test "runs normal flow when LOG_POLLER_SPAWN is unset" do
    ENV.delete("LOG_POLLER_SPAWN")

    # Force LogTail::Feature.enabled? -> true and TailLock/FilePath
    # to their permissive values so every fixture island is
    # enqueued. We replace methods on the singleton classes and
    # restore them in the ensure block.
    LogTail::Feature.singleton_class.define_method(:enabled?) { true }
    LogTail::TailLock.singleton_class.define_method(:held?) { |_| false }
    LogTail::FilePath.singleton_class.define_method(:island_disk_bytes) { |_| 0 }

    begin
      assert_enqueued_jobs Island.count, only: LogTailIslandJob do
        LogTailOrchestratorJob.new.perform
      end
    ensure
      LogTail::Feature.singleton_class.send(:remove_method, :enabled?)
      LogTail::TailLock.singleton_class.send(:remove_method, :held?)
      LogTail::FilePath.singleton_class.send(:remove_method, :island_disk_bytes)
    end
  end
end
