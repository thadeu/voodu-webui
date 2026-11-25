# frozen_string_literal: true

# An alert destination can be email now: the people it tells are org members,
# by user id, and it has no endpoint.
class AddEmailToAlertDestinations < ActiveRecord::Migration[8.1]
  def change
    add_column :alert_destinations, :recipient_ids, :text
    change_column_null :alert_destinations, :endpoint_ciphertext, true
  end
end
