# frozen_string_literal: true

require "test_helper"

# The other acceptance criterion of the queue: a deploy nothing is carrying
# must not stay `running` forever.
#
# DeployRunJob rescues everything it can, but it cannot rescue the process
# being killed mid-deploy. The row that leaves behind says `running` for good,
# and the symptom is worse than a stale row: the screen shows a deploy in
# flight, so the operator waits instead of pushing again.
class DeploymentSweepJobTest < ActiveJob::TestCase
  setup do
    @org = orgs(:acme)
    @server = servers(:alpha)
  end

  test "a running deployment nothing came back for is failed with a next step" do
    deployment = running(started_at: 25.minutes.ago)

    DeploymentSweepJob.perform_now
    deployment.reload

    assert_equal "failed", deployment.status
    assert_match(/no result came back/i, deployment.error)

    # Named, because the deploy may well have SUCCEEDED on the box and only the
    # answer was lost. Telling somebody it failed without that caveat invites a
    # second deploy of a commit that already landed.
    assert_match(/may have completed/i, deployment.error)
    assert_not_nil deployment.finished_at
  end

  # The one thing this job must never do. Marking a live deploy failed puts a
  # lie on the screen AND frees the concurrency key, letting a second deploy
  # race the first.
  test "a deployment still within the window is left alone" do
    deployment = running(started_at: 5.minutes.ago)

    DeploymentSweepJob.perform_now

    assert_equal "running", deployment.reload.status
  end

  test "queued deployments are never swept, however old" do
    deployment = Deployment.create!(
      org: @org, server: @server, repo: "acme/api", sha: "abc1234",
      status: "queued", created_at: 3.days.ago
    )

    DeploymentSweepJob.perform_now

    assert_equal "queued", deployment.reload.status
  end

  test "finished deployments are untouched" do
    deployment = Deployment.create!(
      org: @org, server: @server, repo: "acme/api", sha: "abc1234",
      status: "succeeded", started_at: 3.days.ago, finished_at: 3.days.ago
    )

    DeploymentSweepJob.perform_now

    assert_equal "succeeded", deployment.reload.status
  end

  # started_at and not updated_at: updated_at moves for reasons that have
  # nothing to do with the deploy progressing, so a row touched by an unrelated
  # write would reset its own clock and never be swept.
  test "a stale deployment touched by an unrelated write is still swept" do
    deployment = running(started_at: 25.minutes.ago)
    deployment.touch

    DeploymentSweepJob.perform_now

    assert_equal "failed", deployment.reload.status
  end

  private

  def running(started_at:)
    Deployment.create!(
      org: @org, server: @server, repo: "acme/api", sha: "abc1234",
      status: "running", started_at: started_at
    )
  end
end
