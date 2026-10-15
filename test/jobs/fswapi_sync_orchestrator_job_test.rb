# frozen_string_literal: true

require "test_helper"

# FswapiSyncOrchestratorJob enqueues one overview sync per server that has the
# voodu-fswapi plugin, and nothing for the others.
class FswapiSyncOrchestratorJobTest < ActiveJob::TestCase
  fixtures :orgs, :servers

  def install_plugin(server, name)
    System.create!(
      server: server,
      payload: {host: {}, plugins: [{"name" => name, "aliases" => []}]}.to_json,
      synced_at: Time.current
    )
  end

  test "enqueues a sync only for servers with the plugin" do
    alpha = servers(:alpha)
    install_plugin(alpha, "fswapi")

    assert_enqueued_with(job: FswapiSyncServerJob, args: [alpha.id]) do
      FswapiSyncOrchestratorJob.perform_now
    end

    assert_enqueued_jobs 1, only: FswapiSyncServerJob
  end

  test "another plugin does not turn the sync on" do
    install_plugin(servers(:alpha), "hep3")

    assert_no_enqueued_jobs(only: FswapiSyncServerJob) { FswapiSyncOrchestratorJob.perform_now }
  end
end
