# frozen_string_literal: true

require "test_helper"

class AlertNotifierTest < ActiveJob::TestCase
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @rule = @server.alert_rules.create!(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )
    @event = @rule.alert_events.create!(
      server: @server, state: "firing", started_at: 1.minute.ago,
      threshold: 90, rule_name: @rule.name, metric_kind: "cpu",
      target_label: @rule.target_label
    )
    @firing_only = @server.org.alert_destinations.create!(
      name: "pager", kind: "webhook", endpoint: "https://a.example/h",
      on_firing: true, on_resolved: false
    )
    @both = @server.org.alert_destinations.create!(
      name: "slack", kind: "webhook", endpoint: "https://hooks.slack.com/services/T/B/X",
      on_firing: true, on_resolved: true
    )
    # Wire both to the rule — a rule only notifies the destinations it selects
    # (empty = don't send). The tests below vary the selection + toggles.
    @rule.update!(alert_destinations: [@firing_only, @both])
  end

  test "notifies the selected destinations that want the transition" do
    assert_enqueued_jobs 2, only: DeliverAlertNotificationJob do
      AlertNotifier.enqueue(@event, "firing")
    end
  end

  test "no destinations selected sends nowhere (the don't-send default)" do
    @rule.update!(alert_destinations: [])

    assert_no_enqueued_jobs only: DeliverAlertNotificationJob do
      AlertNotifier.enqueue(@event, "firing")
    end
  end

  test "resolved transition skips firing-only destinations" do
    assert_enqueued_with(job: DeliverAlertNotificationJob, args: [@event.id, @both.id, "resolved"]) do
      AlertNotifier.enqueue(@event, "resolved")
    end
    # only @both wants resolved
    assert_enqueued_jobs 1, only: DeliverAlertNotificationJob
  end

  test "an explicit subset notifies only those destinations" do
    @rule.update!(alert_destinations: [@both])

    assert_enqueued_with(job: DeliverAlertNotificationJob, args: [@event.id, @both.id, "firing"]) do
      AlertNotifier.enqueue(@event, "firing")
    end
    assert_enqueued_jobs 1, only: DeliverAlertNotificationJob
  end

  test "disabled destinations are excluded" do
    @firing_only.update!(enabled: false)
    @both.update!(enabled: false)

    assert_no_enqueued_jobs only: DeliverAlertNotificationJob do
      AlertNotifier.enqueue(@event, "firing")
    end
  end
end
