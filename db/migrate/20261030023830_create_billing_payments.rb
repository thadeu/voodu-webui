# frozen_string_literal: true

# One row per charge ContaGorda Pay reports for an account: the first payment
# of a subscription, each renewal, a declined card, a refund.
#
# The customer's own history, shown beside their plan. The broker's dashboard
# is still the ledger; this is the part of it that belongs to one account, so
# "was I charged this month" is answered without writing to support.
#
# Keyed by the broker's session id: the same charge arrives as session.paid
# and later session.refunded, and both must land on one row.
class CreateBillingPayments < ActiveRecord::Migration[8.1]
  def change
    create_table :billing_payments do |t|
      t.string :account_id, null: false
      t.string :pay_session_id, null: false
      t.string :pay_subscription_id

      t.string :status, null: false
      t.string :description

      # Strings in the broker, decimals here: the screen formats them, and a
      # float would print 9.99 as 9.9900000001 one day.
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.decimal :refunded_amount, precision: 12, scale: 2, null: false, default: 0
      t.string :currency, null: false

      t.datetime :paid_at

      t.timestamps
    end

    add_index :billing_payments, :pay_session_id, unique: true
    add_index :billing_payments, [:account_id, :created_at]
    add_foreign_key :billing_payments, :accounts, on_delete: :cascade
  end
end
