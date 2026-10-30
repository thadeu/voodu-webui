# frozen_string_literal: true

# The subscription a customer of the hosted service pays for, through
# ContaGorda Pay.
#
# On the ACCOUNT, beside the plan license, because both answer the same
# question — "did this customer buy Pro" — from two doors: the console's
# checkout, and a license we issue by hand. Account#plan reads both.
#
# Only the webhook writes these. The return from the checkout is a page for
# the customer to read, not proof of anything: the browser can replay it.
class AddPaySubscriptionToAccounts < ActiveRecord::Migration[8.1]
  def change
    # The broker's id. Unique, because every subscription event finds its
    # account by it — and an event for a subscription that is not the stored
    # one (an old one, replaced) must find nothing.
    add_column :accounts, :pay_subscription_id, :string

    # active, past_due, canceling, canceled. A string the broker's events map
    # onto, not the broker's own vocabulary copied in.
    add_column :accounts, :pay_status, :string

    add_column :accounts, :pay_period_end, :datetime
    add_column :accounts, :pay_cancel_at, :datetime

    add_index :accounts, :pay_subscription_id, unique: true
  end
end
