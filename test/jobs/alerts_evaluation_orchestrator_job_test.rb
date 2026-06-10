# frozen_string_literal: true

require "test_helper"

class AlertsEvaluationOrchestratorJobTest < ActiveJob::TestCase
  fixtures :islands

  test "fans out only to islands with enabled rules" do
    with_rule = islands(:alpha)
    with_rule.alert_rules.create!(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )

    paused = islands(:beta)
    paused.alert_rules.create!(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300,
      enabled: false
    )

    AlertsEvaluationOrchestratorJob.perform_now

    assert_enqueued_with(job: AlertsEvaluationIslandJob, args: [with_rule.id])
    assert_enqueued_jobs 1, only: AlertsEvaluationIslandJob
  end

  test "island job tolerates a deleted island" do
    assert_nothing_raised do
      AlertsEvaluationIslandJob.perform_now(-1)
    end
  end
end
