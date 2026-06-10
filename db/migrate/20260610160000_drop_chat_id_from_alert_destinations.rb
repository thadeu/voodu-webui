# frozen_string_literal: true

# Telegram is no longer a dedicated destination kind — it's just a
# Generic Webhook to api.telegram.org with a body template that
# carries chat_id. So the telegram-only chat_id column is dead.
class DropChatIdFromAlertDestinations < ActiveRecord::Migration[8.1]
  def change
    remove_column :alert_destinations, :chat_id, :string
  end
end
