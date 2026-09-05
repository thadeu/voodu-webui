# frozen_string_literal: true

# WebhookReceiptsSweepJob — retention for the delivery log.
#
# The question this table answers — "did the provider call last month, and what
# did we do" — has a horizon. Ninety days is past every billing cycle and every
# "it broke sometime last quarter" conversation, and short enough that the
# table never becomes the reason to delete the feature.
#
# DELETE AND NOT DESTROY: there are no callbacks to run and no dependents to
# cascade. `deployments.webhook_receipt_id` deliberately carries no foreign
# key, so a swept receipt leaves its deployments intact with a dangling id —
# the screen says the delivery has expired, which is true, and the deploy
# history survives the comprovante that produced it.
#
# In batches, because a delete that locks the table for a second is a delete
# that lands on somebody's webhook.
class WebhookReceiptsSweepJob < ApplicationJob
  queue_as :default

  RETENTION = 90.days

  BATCH = 1_000

  def perform(retention: RETENTION)
    cutoff = retention.ago
    total = 0

    loop do
      ids = Webhook::Receipt.where(received_at: ...cutoff).limit(BATCH).pluck(:id)

      break if ids.empty?

      total += Webhook::Receipt.where(id: ids).delete_all
    end

    Rails.logger.info("[webhooks] swept #{total} receipts older than #{retention.inspect}") if total.positive?

    total
  end
end
