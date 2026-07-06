# frozen_string_literal: true

require "test_helper"

class AlertsEvaluationOrchestratorJobTest < ActiveJob::TestCase
  fixtures :orgs, :servers

  test "fans out only to servers with enabled rules" do
    with_rule = servers(:alpha)
    with_rule.alert_rules.create!(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )

    paused = servers(:beta)
    paused.alert_rules.create!(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300,
      enabled: false
    )

    AlertsEvaluationOrchestratorJob.perform_now

    assert_enqueued_with(job: AlertsEvaluationServerJob, args: [with_rule.id])
    assert_enqueued_jobs 1, only: AlertsEvaluationServerJob
  end

  test "server job tolerates a deleted server" do
    assert_nothing_raised do
      AlertsEvaluationServerJob.perform_now(-1)
    end
  end
end
