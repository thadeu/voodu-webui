# frozen_string_literal: true

# AlertsEvaluationIslandJob — runs the threshold evaluator for ONE
# island. Pure local work (warehouse reads + primary-DB writes), so
# there is no HTTP error surface and no discard_on: anything raised
# here is a bug worth solid_queue's default retry visibility.
class AlertsEvaluationIslandJob < ApplicationJob
  queue_as :default

  def perform(island_id)
    island = Island.find_by(id: island_id)
    return unless island # deleted between orchestrator + job dispatch

    started_at  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    transitions = AlertEvaluator.run(island)
    elapsed_ms  = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

    Rails.logger.info(
      "alerts-eval island=#{island.key} rules=#{island.alert_rules.enabled.count} " \
      "transitions=#{transitions} elapsed=#{elapsed_ms}ms"
    )
  end
end
