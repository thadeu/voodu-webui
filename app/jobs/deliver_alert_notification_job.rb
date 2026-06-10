# frozen_string_literal: true

# DeliverAlertNotificationJob — POSTs one alert transition to one
# destination, in the background. One job per (event, destination,
# transition) so a single slow/broken destination retries in
# isolation without blocking the others.
#
# Retry policy:
#   transport / 5xx / 429 → retry with backoff (transient)
#   4xx / blocked URL     → discard (operator misconfig; retrying
#                           won't help — surfaced via last_error)
class DeliverAlertNotificationJob < ApplicationJob
  queue_as :default

  retry_on WebhookClient::TransportError, WebhookClient::ServerError,
           wait: :polynomially_longer, attempts: 5

  # Permanent failures: don't burn retries. The reason is recorded on
  # the destination (rescue below) before the raise propagates here.
  discard_on WebhookClient::ClientError

  def perform(event_id, destination_id, transition)
    event       = AlertEvent.find_by(id: event_id)
    destination = AlertDestination.find_by(id: destination_id)
    return if event.nil? || destination.nil?
    return unless destination.enabled?

    payload = AlertPayload.for(event, transition, destination)
    WebhookClient.post(destination.endpoint, payload, headers: destination.auth_header)

    destination.update_columns(
      last_delivered_at: Time.current, last_status: "ok", last_error: nil
    )
    Rails.logger.info(
      "alert-notify destination=#{destination.id} kind=#{destination.kind} " \
      "transition=#{transition} status=ok"
    )
  rescue WebhookClient::Error => e
    destination&.update_columns(last_status: "failed", last_error: e.message.first(240))
    Rails.logger.warn(
      "alert-notify destination=#{destination&.id} transition=#{transition} " \
      "failed: #{e.class}: #{e.message}"
    )
    raise # let retry_on / discard_on decide
  end
end
