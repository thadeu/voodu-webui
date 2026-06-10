# frozen_string_literal: true

# Telegram destinations need a chat_id (where to send). It's not a
# secret — a chat/group id — so a plain column, shown back on edit.
# The bot token reuses secret_ciphertext (encrypted credential); the
# sendMessage URL is derived from it at delivery time.
class AddChatIdToAlertDestinations < ActiveRecord::Migration[8.1]
  def change
    add_column :alert_destinations, :chat_id, :string
  end
end
