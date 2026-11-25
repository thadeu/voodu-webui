# frozen_string_literal: true

require "test_helper"

class VooduMailTest < ActionMailer::TestCase
  fixtures :orgs, :servers, :users, :org_memberships

  test "mail goes out through the 1billion gem, from voodu.clowk.in" do
    assert_equal OneBillion::DeliveryMethod, ActionMailer::Base.delivery_methods[:onebillion]

    mail = OrgMailer.invitation(org_memberships(:invitee_in_acme))

    assert_equal "Voodu <hello@voodu.clowk.in>", mail[:from].to_s
  end

  test "an invitation names the org and carries the invite link" do
    membership = org_memberships(:invitee_in_acme)
    membership.update!(invited_by: users(:owner))

    mail = OrgMailer.invitation(membership)

    assert_equal [users(:invitee).email], mail.to
    assert_equal "Operator invited you to #{orgs(:acme).name} on Voodu", mail.subject
    assert_includes mail.body.encoded, "/invites/"
  end

  test "an alert email goes to the chosen people, with the rule, the target and the value" do
    destination, event = email_alert

    mail = AlertMailer.transition(event, "firing", destination)

    assert_equal [users(:owner).email, users(:contractor).email].sort, mail.to.sort
    assert_includes mail.subject, "cpu"
    assert_includes mail.subject, "firing"
    assert_includes mail.body.encoded, "95"
  end

  test "a contact message goes to support with the person as Reply-To" do
    mail = SupportMailer.contact(users(:owner), "We want Enterprise")

    assert_equal ["support@voodu.clowk.in"], mail.to
    assert_equal [users(:owner).email], mail.reply_to
    assert_includes mail.body.encoded, "We want Enterprise"
  end

  private

  def email_alert
    server = servers(:alpha)
    rule = server.alert_rules.create!(name: "cpu", metric_kind: "cpu", target_kind: "host", comparator: "gte", threshold: 90, duration_seconds: 300)
    event = rule.alert_events.create!(server: server, state: "firing", started_at: 2.minutes.ago, threshold: 90, rule_name: "cpu", metric_kind: "cpu", target_label: rule.target_label, peak_value: 95, last_value: 95)
    destination = server.org.alert_destinations.create!(name: "team", kind: "email", recipient_ids: [users(:owner).id, users(:contractor).id])

    [destination, event]
  end
end
