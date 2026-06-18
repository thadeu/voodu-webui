# frozen_string_literal: true

# AlertNotifier — fans an alert transition out to its destinations as
# background delivery jobs. Sibling of AlertsLive: the evaluator calls
# it right after the in-app broadcast on a fire/resolve transition.
#
# Resolves the rule's destinations (explicit subset, or all enabled
# when none are chosen — see AlertRule#destinations_for) and enqueues
# one DeliverAlertNotificationJob each. Enqueue failures are
# logged-and-swallowed: a notification problem must never fail the
# evaluation that already committed the state change.
class AlertNotifier
  def self.enqueue(event, transition)
    rule = event.alert_rule
    return if rule.nil?

    rule.destinations_for(transition).each do |destination|
      DeliverAlertNotificationJob.perform_later(event.id, destination.id, transition)
    end
  rescue => e
    Rails.logger.warn(
      "alert-notify enqueue event=#{event&.id} transition=#{transition} " \
      "failed: #{e.class}: #{e.message}"
    )
  end
end
