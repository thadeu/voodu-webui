# frozen_string_literal: true

# Billing::Receive — a verified event from ContaGorda Pay, applied once.
#
# The broker sends an event again until it gets a 2xx, and retries the SAME id.
# So the id is inserted first and the event is applied only when that insert
# was new. An `exists?` before the insert would be a race: a retry can arrive
# while the attempt it gave up on is still running.
#
# One transaction around both. When Apply raises, the insert rolls back with
# it, the endpoint answers 500 and the broker's retry finds no row — so a
# failure is retried rather than remembered as done.
class Billing::Receive
  def initialize(event)
    @event = event
  end

  def call
    Rails.logger.info("[pay] #{@event.type} #{@event.id}")

    PayEvent.transaction do
      now = Time.current
      row = {event_id: @event.id, event_type: @event.type, created_at: now, updated_at: now}

      fresh = PayEvent.insert_all([row], unique_by: :event_id, returning: :id).any?

      Billing::Apply.new(@event).call if fresh
    end
  end
end
