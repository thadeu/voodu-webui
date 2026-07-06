# frozen_string_literal: true

require "test_helper"

class LogTailOrchestratorJobTest < ActiveJob::TestCase
  fixtures :orgs, :servers

  teardown do
    ENV.delete("POLLER_SPAWN")
  end

  test "early-returns without touching Server when POLLER_SPAWN=1" do
    ENV["POLLER_SPAWN"] = "1"

    # Pin: no Server queries, no enqueues. If perform reached the
    # find_each path, the counter would increment.
    calls = 0
    Server.singleton_class.define_method(:find_each) do |*, **, &blk|
      calls += 1
      blk&.call(Server.first)
    end

    begin
      assert_no_enqueued_jobs do
        LogTailOrchestratorJob.new.perform
      end
      assert_equal 0, calls, "Server.find_each must not be called when POLLER_SPAWN=1"
    ensure
      Server.singleton_class.send(:remove_method, :find_each)
    end
  end

  test "runs normal flow when POLLER_SPAWN is unset" do
    ENV.delete("POLLER_SPAWN")

    # Force LogTail::Feature.enabled? -> true and TailLock/FilePath
    # to their permissive values so every fixture server is
    # enqueued. We replace methods on the singleton classes and
    # restore them in the ensure block.
    LogTail::Feature.singleton_class.define_method(:enabled?) { true }
    LogTail::TailLock.singleton_class.define_method(:held?) { |_| false }
    LogTail::FilePath.singleton_class.define_method(:server_disk_bytes) { |_| 0 }

    begin
      assert_enqueued_jobs Server.count, only: LogTailServerJob do
        LogTailOrchestratorJob.new.perform
      end
    ensure
      LogTail::Feature.singleton_class.send(:remove_method, :enabled?)
      LogTail::TailLock.singleton_class.send(:remove_method, :held?)
      LogTail::FilePath.singleton_class.send(:remove_method, :server_disk_bytes)
    end
  end
end
