# frozen_string_literal: true

require "test_helper"

class StateSyncOrchestratorJobTest < ActiveJob::TestCase
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
        StateSyncOrchestratorJob.new.perform
      end
      assert_equal 0, calls, "Server.find_each must not be called when POLLER_SPAWN=1"
    ensure
      Server.singleton_class.send(:remove_method, :find_each)
    end
  end

  test "runs normal fan-out when POLLER_SPAWN is unset" do
    ENV.delete("POLLER_SPAWN")

    assert_enqueued_jobs Server.count, only: StateSyncServerJob do
      StateSyncOrchestratorJob.new.perform
    end
  end
end
