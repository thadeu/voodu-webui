# frozen_string_literal: true

require "test_helper"

# Hep3SyncOrchestratorJob fans out one poller per (island, reader), gated
# on local state. These pin the gate: an island gets pollers ONLY when its
# controller has the hep3 plugin installed AND a reader is configured —
# the whole "feature off unless the plugin is there" premise.
class Hep3SyncOrchestratorJobTest < ActiveJob::TestCase
  fixtures :islands

  def install_hep3(island)
    System.create!(
      island: island,
      payload: {host: {}, plugins: [{"name" => "hep3", "aliases" => ["hep"]}]}.to_json,
      synced_at: Time.current
    )
  end

  test "enqueues a poller per reader, only for islands with the plugin" do
    alpha = islands(:alpha)
    install_hep3(alpha)
    alpha.hep3_readers = ["fsw/hep3-api"]

    # beta has no system snapshot → plugin_installed? false → skipped.

    assert_enqueued_with(job: Hep3PollerJob, args: [alpha.id, "fsw", "hep3-api"]) do
      Hep3SyncOrchestratorJob.perform_now
    end

    assert_enqueued_jobs 1, only: Hep3PollerJob
  end

  test "skips an island that has the plugin but no reader configured" do
    install_hep3(islands(:alpha))
    # no hep3_readers set

    assert_no_enqueued_jobs only: Hep3PollerJob do
      Hep3SyncOrchestratorJob.perform_now
    end
  end

  test "skips an island with readers configured but the plugin absent" do
    islands(:alpha).hep3_readers = ["fsw/hep3-api"]
    # no System row → plugin_installed?("hep3") is false.

    assert_no_enqueued_jobs only: Hep3PollerJob do
      Hep3SyncOrchestratorJob.perform_now
    end
  end
end
