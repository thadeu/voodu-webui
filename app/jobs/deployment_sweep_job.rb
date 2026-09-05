# frozen_string_literal: true

# DeploymentSweepJob — closes deployments nothing is carrying any more.
#
# WHY IT HAS TO EXIST. DeployRunJob rescues everything it can and marks the row
# failed, but there is one thing it cannot rescue: the process being killed
# mid-deploy. A deploy started at 3pm on a worker that was terminated at 3:01
# leaves a row saying `running` with nobody running it — and it says that
# forever, because the only code that would have changed it is gone.
#
# The symptom is worse than a stale row: the screen shows a deploy in flight,
# so the operator waits instead of pushing again.
#
# STALE_AFTER is above DeployRunJob's own 600s timeout with room to spare. A
# deploy still legitimately in flight must never be swept — marking a live
# deploy failed would put a lie on the screen and, worse, free the concurrency
# key for a second deploy to race the first.
class DeploymentSweepJob < ApplicationJob
  queue_as :default

  STALE_AFTER = 20.minutes

  def perform
    cutoff = STALE_AFTER.ago

    # started_at and not updated_at: updated_at moves for reasons that have
    # nothing to do with the deploy progressing, and a row touched by an
    # unrelated write would reset its own clock and never be swept.
    stale = Deployment.running.where(started_at: ..cutoff)

    stale.find_each do |deployment|
      Rails.logger.warn("[deploy] sweeping orphaned deployment #{deployment.id} (#{deployment.repo})")

      deployment.fail!(
        "No result came back within #{STALE_AFTER.inspect}. The deploy may have completed on the " \
        "server — check its activity trail before pushing again."
      )
    end
  end
end
