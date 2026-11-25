# frozen_string_literal: true

# AlertMailer — one alert transition (firing or resolved) to the people of an
# email destination. The values come from the event snapshot, formatted the
# same way as the webhook template tokens.
class AlertMailer < ApplicationMailer
  def transition(event, transition, destination)
    @tokens = AlertPayload.new(event, transition, destination).template_tokens

    mail(
      to: destination.recipients,
      subject: "[Voodu] #{@tokens["rule"]} is #{@tokens["state"]} on #{@tokens["target"]}"
    )
  end
end
