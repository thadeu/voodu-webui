# frozen_string_literal: true

# AlertsEvaluationOrchestratorJob — fans out one evaluation job per
# island that actually has enabled rules. Recurs every 30s (see
# config/recurring.yml).
#
# No POLLER_SPAWN guard on purpose: unlike the sync orchestrators,
# evaluation never touches the controller — it reads the local
# warehouse regardless of which process fills it (Ruby jobs or the
# Go poller), so it must keep running in both modes.
class AlertsEvaluationOrchestratorJob < ApplicationJob
  queue_as :default

  def perform
    Island.joins(:alert_rules)
          .where(alert_rules: { enabled: true })
          .distinct
          .find_each do |island|
      AlertsEvaluationIslandJob.perform_later(island.id)
    end
  end
end
