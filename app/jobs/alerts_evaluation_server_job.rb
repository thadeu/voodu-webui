# frozen_string_literal: true

# AlertsEvaluationServerJob — runs the threshold evaluator for ONE
# server. Pure local work (warehouse reads + primary-DB writes), so
# there is no HTTP error surface and no discard_on: anything raised
# here is a bug worth solid_queue's default retry visibility.
class AlertsEvaluationServerJob < ApplicationJob
  queue_as :default

  def perform(server_id)
    server = Server.find_by(id: server_id)
    return unless server # deleted between orchestrator + job dispatch

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    transitions = AlertEvaluator.run(server)
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

    Rails.logger.info(
      "alerts-eval server=#{server.key} rules=#{server.alert_rules.enabled.count} " \
      "transitions=#{transitions} elapsed=#{elapsed_ms}ms"
    )
  end
end
