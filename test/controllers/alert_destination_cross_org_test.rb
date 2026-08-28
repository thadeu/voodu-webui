# frozen_string_literal: true

require "test_helper"

# An alert rule notifies through `alert_destination_ids`, which arrives straight
# from the form. The rule already validates that its TARGET SERVER is in the org
# (AlertRule#target_server_in_org) — its destinations had no such guard, and
# `alert_rule_destinations` carries no org_id, so nothing downstream could tell
# a foreign row from a legitimate one.
#
# The consequence was a cross-org WRITE, not a read: wire your rule to another
# org's destination and their webhook receives your payloads, with the delivery
# result stamped on their row.
#
# Three layers are pinned here, because each covers a case the others cannot:
# the controller filters on the way in (the only layer that can, since assigning
# `alert_destination_ids` on a persisted rule writes the join before validation
# runs), the model catches every other caller, and the job refuses to deliver on
# a bad row that somehow exists.
class AlertDestinationCrossOrgTest < ActionDispatch::IntegrationTest
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)          # acme
    @foreign = servers(:gamma)         # globex — a different org
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"

    @foreign_destination = @foreign.org.alert_destinations.create!(
      name: "globex-oncall", kind: "webhook", endpoint: "https://globex.example/hook"
    )
  end

  teardown { ENV["WAREHOUSE"] = @prev_wh }

  test "creating a rule drops a destination id from another org" do
    post alert_rules_path(server_key: @server.key), params: {
      alert_rule: rule_params.merge(alert_destination_ids: [@foreign_destination.id])
    }

    rule = AlertRule.order(:id).last

    assert_not_nil rule, "the rule itself is legitimate and must still save"
    assert_empty rule.alert_destinations,
      "a destination outside the org must never be wired to the rule"
  end

  test "updating a rule cannot wire in another org's destination" do
    rule = create_rule

    patch alert_rule_path(server_key: @server.key, id: rule.id), params: {
      alert_rule: rule_params.merge(alert_destination_ids: [@foreign_destination.id])
    }

    assert_empty rule.reload.alert_destinations
    assert_empty AlertRuleDestination.where(alert_destination_id: @foreign_destination.id),
      "the join row is written the moment the ids are assigned — it must never be reached"
  end

  test "the model refuses a foreign destination whatever the caller" do
    rule = orgs(:acme).alert_rules.new(
      name: "Host CPU ≥ 90%", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300,
      server: @server, alert_destinations: [@foreign_destination]
    )

    assert_not rule.valid?
    assert_includes rule.errors[:alert_destinations], "must belong to this org"
  end

  # The last line: even with a join row that should never have existed, the job
  # must not post one org's payload to another org's endpoint.
  test "the delivery job refuses a destination outside the event's org" do
    rule = create_rule
    AlertRuleDestination.create!(alert_rule: rule, alert_destination: @foreign_destination)
    event = rule.alert_events.create!(
      org: rule.org, server: @server, state: "firing", started_at: Time.current,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu", target_label: "alpha"
    )

    DeliverAlertNotificationJob.perform_now(event.id, @foreign_destination.id, "firing")

    assert_nil @foreign_destination.reload.last_status,
      "delivering would both leak the payload and stamp the other org's row"
  end

  private

  def rule_params
    {
      name: "Host CPU ≥ 90%", metric_kind: "cpu", target: "host|#{@server.id}",
      comparator: "gte", threshold: 90, duration_seconds: 300
    }
  end

  def create_rule
    @server.alert_rules.create!(
      name: "Host CPU ≥ 90%", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )
  end
end
