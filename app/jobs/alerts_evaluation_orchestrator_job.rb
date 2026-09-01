# frozen_string_literal: true

# AlertsEvaluationOrchestratorJob — fans out one evaluation job per
# server that actually has enabled rules. Recurs every 30s (see
# config/recurring.yml).
#
# Evaluation never touches the controller — it reads the local warehouse
# the Go poller fills — which is why it stayed a Ruby job when the fetching
# did not: rules, thresholds and notifications are the app's business.
class AlertsEvaluationOrchestratorJob < ApplicationJob
  queue_as :default

  def perform
    Server.joins(:alert_rules)
      .where(alert_rules: {enabled: true})
      .distinct
      .find_each do |server|
      AlertsEvaluationServerJob.perform_later(server.id)
    end
  end
end
