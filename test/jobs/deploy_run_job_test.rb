# frozen_string_literal: true

require "test_helper"

# The queue: what reaches the box, what waits, and what is never carried at all.
#
# The two acceptance criteria of the ticket are the two tests that matter here:
# two pushes to one repository must not apply in parallel, and a deploy nothing
# is carrying must not stay `running` forever. Everything else is the row
# ending in a state a screen can explain.
class DeployRunJobTest < ActiveJob::TestCase
  INSTALLATION = "9001"
  REPO = "acme/api"

  setup do
    @env = ENV.to_hash.slice("GITHUB_APP_ID", "GITHUB_APP_PRIVATE_KEY")
    ENV["GITHUB_APP_ID"] = "12345"
    ENV["GITHUB_APP_PRIVATE_KEY"] = KEY

    @org = orgs(:acme)
    @server = servers(:alpha)
    @integration = Integration::Record.create!(
      org: @org, name: "GitHub", provider: "github",
      external_id: INSTALLATION, status: "active"
    )

    stub_token
  end

  teardown do
    %w[GITHUB_APP_ID GITHUB_APP_PRIVATE_KEY].each { |key| ENV.delete(key) }
    @env.each { |key, value| ENV[key] = value }
  end

  test "a queued deployment reaches the box and records what was applied" do
    deployment = queued
    stub_run(applied: ["web", "worker"], job_id: "job-1")

    DeployRunJob.perform_now(deployment.id)
    deployment.reload

    assert_equal "succeeded", deployment.status
    assert_equal "job-1", deployment.remote_job_id
    assert_equal ["web", "worker"], deployment.applied
    assert_not_nil deployment.started_at
    assert_not_nil deployment.finished_at
  end

  # An empty `applied` is NOT a failure. Pushing a README change to a
  # repository that watches `app/**` is the normal case, and coloring it red
  # trains operators to ignore red.
  test "a push that matched no trigger file is skipped, not failed" do
    deployment = queued
    stub_run(applied: [], skipped: ["no path matched"])

    DeployRunJob.perform_now(deployment.id)
    deployment.reload

    assert_equal "skipped", deployment.status
    assert_match(/nothing matched/i, deployment.skipped_reason)
  end

  # THE ACCEPTANCE CRITERION: what matters is the last SHA, not the order of
  # arrival. Three pushes while the first applies should end at the third —
  # each intermediate apply restarts containers to reach a state nobody asked
  # to stay in.
  test "a deployment overtaken by a newer push is skipped without touching the box" do
    older = queued(sha: "aaa1111")
    travel 1.second
    newer = queued(sha: "bbb2222")

    # No stub at all: the default WebMock rule times out every non-local host,
    # so if this job reached the box the test would fail rather than pass
    # quietly.
    DeployRunJob.perform_now(older.id)

    assert_equal "skipped", older.reload.status
    assert_match(/superseded by #{newer.short_sha}/, older.skipped_reason)
    assert_equal "queued", newer.reload.status
  end

  test "the newest deployment is not superseded by anything" do
    queued(sha: "aaa1111")
    travel 1.second
    newest = queued(sha: "bbb2222")

    stub_run(applied: ["web"])

    DeployRunJob.perform_now(newest.id)

    assert_equal "succeeded", newest.reload.status
  end

  # Only within the same key. Two repositories on one server, or one
  # repository on two servers, are independent deploys.
  test "a push to another repository does not supersede this one" do
    mine = queued(sha: "aaa1111")
    travel 1.second
    queued(sha: "bbb2222", repo: "acme/other")

    stub_run(applied: ["web"])

    DeployRunJob.perform_now(mine.id)

    assert_equal "succeeded", mine.reload.status
  end

  # THE OTHER HALF of "two pushes do not apply in parallel". `superseded_by`
  # decides what to skip once a job RUNS; this decides what may run at all.
  #
  # Pinned as a value because the lambda is one edit from returning something
  # constant — and a constant key would serialize every deploy on the
  # installation behind one another, which looks like the feature working
  # until somebody notices staging waiting on production.
  test "the concurrency key is per server and repository" do
    mine = queued
    other_repo = queued(repo: "acme/other")

    key = DeployRunJob.concurrency_key

    assert_equal "#{@server.id}:#{REPO}", key.call(mine.id)
    assert_equal "#{@server.id}:acme/other", key.call(other_repo.id)
    assert_not_equal key.call(mine.id), key.call(other_repo.id)
  end

  test "the same repository on two servers does not share a concurrency key" do
    mine = queued

    elsewhere = Deployment.create!(
      org: @org, server: servers(:beta), integration: @integration,
      repo: REPO, sha: "abc1234", trigger_id: "t1", status: "queued"
    )

    key = DeployRunJob.concurrency_key

    assert_not_equal key.call(mine.id), key.call(elsewhere.id)
  end

  # ── failures the row has to explain ────────────────────────────────────

  test "an unreachable server fails the deployment with the server named" do
    deployment = queued

    DeployRunJob.perform_now(deployment.id)
    deployment.reload

    assert_equal "failed", deployment.status
    assert_includes deployment.error, @server.name
  end

  test "a server whose token lacks the deploy scope says which scope" do
    deployment = queued
    stub_request(:post, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/deploy/triggers})
      .to_return(status: 403, body: {status: "error", error: "insufficient scope"}.to_json,
        headers: {"Content-Type" => "application/json"})

    DeployRunJob.perform_now(deployment.id)

    assert_equal "failed", deployment.reload.status
    assert_match(/deploy scope/i, deployment.error)
  end

  test "a disconnected integration fails rather than raising" do
    deployment = queued
    deployment.update!(integration: nil)

    DeployRunJob.perform_now(deployment.id)

    assert_equal "failed", deployment.reload.status
    assert_match(/GitHub connection/i, deployment.error)
  end

  test "a deployment with no trigger on the box fails with that reason" do
    deployment = queued
    deployment.update!(trigger_id: nil)

    DeployRunJob.perform_now(deployment.id)

    assert_equal "failed", deployment.reload.status
    assert_match(/no trigger/i, deployment.error)
  end

  # A row must never be left saying `running` because of an unexpected error —
  # the screen would show a deploy in flight that nothing is carrying.
  test "an unexpected error still lands the row in a finished state" do
    deployment = queued

    Integration::Github::Client.stub(:new, ->(*) { raise "boom" }) do
      DeployRunJob.perform_now(deployment.id)
    end

    assert_equal "failed", deployment.reload.status
  end

  test "a deployment already finished is not run again" do
    deployment = queued
    deployment.succeed!(remote_job_id: "job-1")

    DeployRunJob.perform_now(deployment.id)

    assert_equal "succeeded", deployment.reload.status
    assert_equal "job-1", deployment.remote_job_id
  end

  test "a deleted deployment is a no-op rather than an exception" do
    assert_nothing_raised { DeployRunJob.perform_now(-1) }
  end

  private

  KEY = OpenSSL::PKey::RSA.generate(2048).to_pem

  def queued(sha: "abc1234", repo: REPO)
    Deployment.create!(
      org: @org, server: @server, integration: @integration,
      repo: repo, ref: "refs/heads/main", sha: sha,
      trigger_id: "t1", status: "queued", delivery_id: SecureRandom.uuid
    )
  end

  def stub_token
    WebMock.stub_request(:post, "https://api.github.com/app/installations/#{INSTALLATION}/access_tokens")
      .to_return(status: 201, body: {token: "ghs_test"}.to_json,
        headers: {"Content-Type" => "application/json"})
  end

  def stub_run(applied:, skipped: [], held: [], job_id: "job-1", log: nil)
    WebMock.stub_request(:post, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/deploy/triggers})
      .to_return(status: 200, body: {
        status: "ok",
        data: {job_id: job_id, trigger: "t1", repo: REPO, commit: "abc1234",
               applied: applied, skipped: skipped, held: held, log: log}.compact
      }.to_json, headers: {"Content-Type" => "application/json"})
  end

  # ── the log ────────────────────────────────────────────────────────────
  #
  # `error` is one line. The reason a build broke is in the output above it,
  # and a screen that shows "failed" without that output sends the operator
  # to the box's journal for something the box already sent us.

  test "a successful deploy keeps the box's build and release output" do
    deployment = queued
    stub_run(applied: ["web"], log: "-----> building release\n-----> Release r1: command\n")

    DeployRunJob.perform_now(deployment.id)
    deployment.reload

    assert_equal "succeeded", deployment.status
    assert_includes deployment.log, "Release r1: command"
  end

  test "a failed deploy keeps the output the box sent with its refusal" do
    deployment = queued
    WebMock.stub_request(:post, %r{#{Regexp.escape(@server.endpoint)}/api/pat/v1/deploy/triggers})
      .to_return(status: 422, body: {
        status: "error", error: "release of clowk/web failed: exit 1",
        data: {log: "-----> Release r1: command\nrails aborted!\nPG::UndefinedTable\n"}
      }.to_json, headers: {"Content-Type" => "application/json"})

    DeployRunJob.perform_now(deployment.id)
    deployment.reload

    assert_equal "failed", deployment.status
    assert_equal "release of clowk/web failed: exit 1", deployment.error
    assert_includes deployment.log, "PG::UndefinedTable"
  end

  test "a box that sends no log stores none" do
    deployment = queued
    stub_run(applied: ["web"])

    DeployRunJob.perform_now(deployment.id)
    deployment.reload

    assert_equal "succeeded", deployment.status
    assert_not deployment.details.key?("log")
    assert_equal "", deployment.log
  end

  # ── deploy: manual ─────────────────────────────────────────────────────

  # The box applied nothing because every matching file said manual. That is
  # neither skipped nor failed: it is a row waiting for a person.
  test "a push every trigger file holds lands as held, with the files named" do
    deployment = queued
    stub_run(applied: [], held: ["API"])

    DeployRunJob.perform_now(deployment.id)
    deployment.reload

    assert_equal "held", deployment.status
    assert_equal ["API"], deployment.held
    assert deployment.dispatchable?
    assert_not_nil deployment.finished_at
  end

  test "a push that applied some files and held others succeeds and keeps the held list" do
    deployment = queued
    stub_run(applied: ["Web"], held: ["API"])

    DeployRunJob.perform_now(deployment.id)
    deployment.reload

    assert_equal "succeeded", deployment.status
    assert_equal ["API"], deployment.held
    assert deployment.dispatchable?
  end

  # THE FEATURE: a person pressing play on push-1 while push-3 sits held has
  # chosen push-1. "Last SHA wins" is for pushes, never for dispatches.
  test "a dispatch is not superseded by a newer held push and tells the box it is a dispatch" do
    older = queued(sha: "aaa1111")
    stub_run(applied: [], held: ["API"])
    DeployRunJob.perform_now(older.id)

    queued(sha: "bbb2222")

    older.reload.dispatch!(by: "dev@example.com")
    stub_run(applied: ["API"])

    DeployRunJob.perform_now(older.id)
    older.reload

    assert_equal "succeeded", older.status
    assert_equal "dev@example.com", older.dispatched_by
    assert_requested(:post, %r{/deploy/triggers/t1/run}, times: 1) { |req|
      JSON.parse(req.body)["mode"] == "dispatch" && JSON.parse(req.body)["sha"] == "aaa1111"
    }
  end

  # First play reuses the row; the next one is a re-run and gets its own row,
  # so the first outcome is never overwritten.
  test "a second dispatch creates a new row pointing at the first" do
    deployment = queued
    deployment.update!(status: "held", finished_at: Time.current, details: {"held" => ["API"]})

    first = deployment.dispatch!(by: "a@example.com")
    assert_equal deployment.id, first.id
    first.update!(status: "succeeded", finished_at: Time.current)

    second = deployment.reload.dispatch!(by: "b@example.com")

    assert_not_equal deployment.id, second.id
    assert_equal deployment.id, second.parent_id
    assert_equal "queued", second.status
    assert_equal ["API"], second.held
    assert_equal "succeeded", deployment.reload.status
    assert_nil second.delivery_id
  end

  test "a row in flight cannot be dispatched again" do
    deployment = queued
    deployment.update!(details: {"held" => ["API"]})

    assert_not deployment.dispatchable?
  end
end
