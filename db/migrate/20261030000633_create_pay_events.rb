# frozen_string_literal: true

# One row per ContaGorda Pay event we applied — the dedupe and nothing else.
#
# NOT webhook_receipts, though that table was written for "Stripe next". Its
# listing shows rows with no org to every org, on the Deploys screen, and a
# billing event names a customer and their email. A table of its own keeps a
# payment out of a screen about pushes.
#
# The broker sends the same event again until it gets a 2xx, with the same id.
# The unique index turns "did we already apply this" into an insert that does
# nothing — see Billing::Receive.
class CreatePayEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :pay_events do |t|
      t.string :event_id, null: false
      t.string :event_type, null: false

      t.timestamps
    end

    add_index :pay_events, :event_id, unique: true
  end
end
