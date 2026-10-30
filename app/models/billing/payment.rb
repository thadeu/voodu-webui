# frozen_string_literal: true

# Billing::Payment — one charge of an account's subscription, as ContaGorda Pay
# reported it. Written only by Billing::Apply; see the migration for why it
# exists beside the broker's own ledger.
class Billing::Payment < ApplicationRecord
  self.table_name = "billing_payments"

  STATUSES = %w[paid failed refunded].freeze

  belongs_to :account

  validates :pay_session_id, presence: true
  validates :status, inclusion: {in: STATUSES}

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  # A refund that did not return the whole charge. Shown as its own state:
  # "refunded" on a payment the customer got half of back would be a lie in
  # the customer's favour, and they would be right to ask about it.
  def partially_refunded? = status == "refunded" && refunded_amount < amount
end
