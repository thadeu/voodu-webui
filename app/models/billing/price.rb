# frozen_string_literal: true

# Billing::Price — what Pro costs on the hosted service.
#
# From the environment, so a price change is a deploy and not a release. There
# is no price object at the broker: the checkout sends the amount every time,
# and a subscription keeps the amount it was opened with.
class Billing::Price
  INTERVAL = "month"

  def self.pro
    new(amount: ENV.fetch("PRO_PLAN_PRICE", "9.99"), currency: ENV.fetch("PRO_PLAN_CURRENCY", "USD"))
  end

  attr_reader :amount, :currency

  def initialize(amount:, currency:)
    @amount = format("%.2f", BigDecimal(amount.to_s))
    @currency = currency.to_s.upcase
  end

  def interval = INTERVAL

  # "$9.99/mo" for dollars; any other currency names itself, because a "$"
  # in front of a price in reais is a price in the wrong currency.
  def label
    prefix = (currency == "USD") ? "$" : "#{currency} "

    "#{prefix}#{amount}/mo"
  end
end
