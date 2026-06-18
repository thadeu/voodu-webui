# frozen_string_literal: true

# Alert destinations — shared, island-scoped notification targets that
# rules fire requests to (Slack incoming webhook or a generic JSON
# webhook). Configured once per island; rules reference a subset (or
# all) via the alert_rule_destinations join.
#
# The endpoint (Slack/webhook URL — carries a token) and optional
# secret are encrypted at rest via ActiveRecord Encryption, same as
# the island PAT. last_* columns are lightweight delivery
# observability (no per-event log table in v1).
class CreateAlertDestinations < ActiveRecord::Migration[8.1]
  def change
    create_table :alert_destinations do |t|
      t.references :island, null: false, foreign_key: {on_delete: :cascade}
      t.string :name, null: false
      t.string :kind, null: false
      t.text :endpoint_ciphertext, null: false
      t.text :secret_ciphertext
      t.boolean :on_firing, null: false, default: true
      t.boolean :on_resolved, null: false, default: true
      t.boolean :enabled, null: false, default: true

      t.datetime :last_delivered_at
      t.string :last_status
      t.string :last_error

      t.timestamps
    end

    add_index :alert_destinations, [:island_id, :name], unique: true
    add_index :alert_destinations, [:island_id, :enabled]
  end
end
