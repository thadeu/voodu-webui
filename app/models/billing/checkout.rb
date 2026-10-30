# frozen_string_literal: true

# Billing::Checkout — opens a ContaGorda Pay checkout for Pro and answers the
# URL to send the owner to.
#
# The account does NOT change here. The plan moves when subscription.activated
# arrives at the webhook (Billing::Apply), because a checkout that was opened
# is not a checkout that was paid.
#
# The account's id is the customer's external_ref, and every event brings it
# back as customer_ref. The id and not the short_id: the short_id is what the
# URLs show, and the thing a payment is matched to should not be the thing a
# customer can read off the screen.
class Billing::Checkout
  DESCRIPTION = "Voodu Pro"

  def initialize(account:, email:, return_to:, price: Billing::Price.pro, client: ContaGorda::Pay::Client.new)
    @account = account
    @email = email
    @return_to = return_to
    @price = price
    @client = client
  end

  # A unique idempotency key per click: the key exists so a network retry of
  # ONE request does not open two checkouts, not to fold two clicks into one.
  def redirect_url
    response = @client.connect(idempotency_key: "voodu-#{@account.id}-pro-#{SecureRandom.uuid}", **body)
    url = response[:redirect_url].to_s

    raise ContaGorda::Pay::Error, "checkout answered without an https redirect_url" unless url.start_with?("https://")

    url
  end

  private

  def body
    {
      amount: @price.amount,
      currency: @price.currency,
      interval: @price.interval,
      description: DESCRIPTION,
      return_to: @return_to,
      metadata: {account_id: @account.id, plan: "pro", description: DESCRIPTION},
      customer: {external_ref: @account.id, email: @email, name: @account.name}
    }
  end
end
