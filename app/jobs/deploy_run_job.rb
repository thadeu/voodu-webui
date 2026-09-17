# frozen_string_literal: true

# DeployRunJob — one queued deployment, carried to the box.
#
# ONE IN FLIGHT PER SERVER AND REPOSITORY. Two pushes a minute apart must not
# apply in parallel on the same box: the second would race the first's
# reconcile and the box would end in whichever state finished last, which is
# not necessarily the newer commit.
#
# `duration` is not a timeout on the work — it is how long the semaphore is
# held if this process dies mid-job. Without it a killed worker blocks every
# later deploy of that repository forever, and the fix would be a console.
#
# THE LAST SHA WINS. Three pushes while the first is applying should end at the
# third, not walk through all three: each intermediate apply restarts
# containers to reach a state nobody asked to stay in. See `superseded_by`.
class DeployRunJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, duration: 15.minutes,
    key: ->(deployment_id) { Deployment.where(id: deployment_id).pick(:server_id, :repo)&.join(":") }

  # No retries. A deploy that failed on the box failed for a reason the box
  # already reported — a bad manifest, a build that did not compile, a token
  # that expired — and none of those get better by being tried again in thirty
  # seconds. Re-running is a decision a person makes, from the screen.
  discard_on ActiveJob::DeserializationError

  def perform(deployment_id)
    deployment = Deployment.find_by(id: deployment_id)

    return if deployment.nil? || !deployment.queued?

    # A dispatch is never superseded. "Last SHA wins" exists so three pushes
    # in a minute do not walk production through all three; a person pressing
    # play on push-1 while push-3 sits held has chosen push-1, and that is the
    # whole feature.
    newer = deployment.dispatch? ? nil : deployment.superseded_by

    return deployment.skip!("superseded by #{newer.short_sha}") if newer

    deployment.start!

    run(deployment)
  rescue => e
    # Broad on purpose: whatever went wrong, the row must not be left saying
    # `running` — the screen would show a deploy in flight that nothing is
    # carrying, and the sweeper would take twenty minutes to notice.
    Rails.logger.error("[deploy] #{deployment_id} failed: #{e.class}: #{e.message}")
    deployment&.fail!("#{e.class}: #{e.message}")
  end

  private

  def run(deployment)
    integration = deployment.integration

    return deployment.fail!("The GitHub connection for this repository is gone.") if integration.nil?
    return deployment.fail!("This repository has no trigger on #{deployment.server.name}.") if deployment.trigger_id.blank?

    token = Integration::Github::Client.new.installation_token(integration.installation_id)

    result = Voodu::Client.new(deployment.server, timeout: TIMEOUT).deploy_run(
      trigger: deployment.trigger_id, sha: deployment.sha, ref: deployment.ref, token: token,
      mode: deployment.dispatch? ? "dispatch" : nil,
      changed: deployment.details["changed_paths"]
    )

    finish(deployment, result)
  rescue Voodu::Client::TransportError => e
    deployment.fail!("#{deployment.server.name} did not answer: #{e.message}")
  rescue Voodu::Client::AuthError
    deployment.fail!("This server's token cannot deploy — it needs the deploy scope.")
  rescue Voodu::Client::Error => e
    deployment.fail!(e.message, log: e.data&.dig("log"))
  rescue Integration::Github::Client::Error, Integration::Github::AppJwt::MissingCredentials => e
    deployment.fail!("Could not mint a GitHub token: #{e.class}")
  end

  # The box applies synchronously and answers with what it did. An empty
  # `applied` is NOT a failure: it means the push did not match any trigger
  # file's branch or watched paths, which is the normal outcome of pushing a
  # README change to a repository that watches `app/**`.
  #
  # An empty `applied` with a non-empty `held` is a third thing: every file
  # that matched said `deploy: manual`. The row waits for a person, and the
  # screen puts a play button on it.
  def finish(deployment, result)
    applied = Array(result["applied"])
    skipped = Array(result["skipped"])
    held = Array(result["held"])
    log = result["log"].presence

    return deployment.hold!(held, remote_job_id: result["job_id"], log: log) if applied.empty? && held.any?

    if applied.empty?
      return deployment.skip!(
        skipped.any? ? "nothing matched this push (#{skipped.join(", ")})" : "nothing matched this push",
        log: log
      )
    end

    deployment.succeed!(
      remote_job_id: result["job_id"], applied: applied, skipped: skipped.presence,
      resources: Array(result["resources"]), held: held, log: log
    )
  end

  # Longer than the client's default six seconds, and deliberately so: the box
  # downloads a tarball, may build an image, and then applies. Six seconds is
  # right for a screen waiting on a list; it is not right for this.
  TIMEOUT = 600
end
