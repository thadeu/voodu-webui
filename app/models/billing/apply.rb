# frozen_string_literal: true

# Billing::Apply — what a ContaGorda Pay event does to an account.
#
# The ONLY writer of the pay_* columns. The return from the checkout chooses a
# message and nothing else; the plan moves here, from a signed event.
#
#   subscription.activated  Pro starts
#   subscription.renewed    a new period is paid
#   subscription.updated    the period end or cancel_at changed, the status did not
#   subscription.past_due   a renewal failed and the gateway retries — still Pro
#   subscription.canceling  a cancellation is set for cancel_at — still Pro
#   subscription.resumed    the cancellation is taken back
#   subscription.canceled   back to Free
#   session.refunded        a FULL refund of the current subscription ends it now
#   session.paid/failed/refunded  one Billing::Payment row per charge
#
# Everything else (ping, disputes, …) is accepted and does nothing.
#
# Every subscription event other than `activated` finds its account by the
# subscription id, never by customer_ref. After a re-subscription the old
# subscription still sends its own `canceled`, and it must find nothing rather
# than take Pro away from the account that just paid for the new one.
class Billing::Apply
  PLAN = "pro"

  PAYMENT_STATUSES = {
    "session.paid" => "paid",
    "session.failed" => "failed",
    "session.refunded" => "refunded"
  }.freeze

  def initialize(event)
    @event = event
  end

  def call
    case @event.type
    when "subscription.activated" then activate
    when "subscription.renewed" then current { |account| account.update!(pay_status: "active", pay_period_end: period_end || account.pay_period_end) }
    when "subscription.updated" then current { |account| sync(account) }
    when "subscription.past_due" then current { |account| account.update!(pay_status: "past_due") }
    when "subscription.canceling" then current { |account| account.update!(pay_status: "canceling", pay_cancel_at: time(subscription[:cancel_at])) }
    when "subscription.resumed" then current { |account| account.update!(pay_status: "active", pay_cancel_at: nil) }
    when "subscription.canceled" then current { |account| end_plan(account) }
    when *PAYMENT_STATUSES.keys then record_payment(PAYMENT_STATUSES.fetch(@event.type))
    end

    take_plan_back if @event.type == "session.refunded" && full_refund?
  end

  private

  def subscription = @event.subscription || ContaGorda::Pay::Resource.new

  def session = @event.session || ContaGorda::Pay::Resource.new

  def period_end = time(subscription[:current_period_end])

  # The one event that finds its account by customer_ref: the subscription is
  # new, so nothing stores its id yet. The plan in the metadata is checked so a
  # checkout opened for something else one day does not turn into Pro.
  def activate
    account = Account.find_by(id: @event.customer_ref)

    return if account.nil? || subscription[:id].blank? || @event.metadata[:plan] != PLAN

    account.update!(
      pay_subscription_id: subscription[:id],
      pay_status: "active",
      pay_period_end: period_end,
      pay_cancel_at: nil
    )
  end

  def current
    return if subscription[:id].blank?

    account = Account.find_by(pay_subscription_id: subscription[:id])

    yield account if account
  end

  # The fields, as the broker has them now. Most often the period end: a
  # checkout's `activated` goes out before the gateway reports it, so it
  # arrives here seconds later. A cancel_at means a cancellation is
  # scheduled — possibly from the gateway's own dashboard, which sends no
  # `canceling` — and none means it is not. past_due stays past_due: only a
  # paid renewal ends that.
  def sync(account)
    cancel_at = time(subscription[:cancel_at])
    status = if account.pay_status == "past_due" then "past_due"
    elsif cancel_at then "canceling"
    else "active"
    end

    account.update!(pay_status: status, pay_period_end: period_end || account.pay_period_end, pay_cancel_at: cancel_at)
  end

  # The id stays: it is what an old event is matched against, and it names
  # the subscription in support questions after the fact.
  def end_plan(account)
    account.update!(pay_status: "canceled", pay_cancel_at: nil)
  end

  # session.refunded comes on EVERY refund, with the total refunded so far. A
  # partial refund is a goodwill gesture and keeps Pro; the one that completes
  # the refund means the customer has their money back, and the plan ends now.
  def full_refund?
    refunded = BigDecimal(session[:refunded_amount].to_s)

    refunded.positive? && refunded >= BigDecimal(session[:amount].to_s)
  rescue ArgumentError
    false
  end

  # Cancelled at the broker FIRST. If that call fails, this raises, the event
  # is not marked as applied, and the broker's retry tries again — Free here
  # with the subscription still charging there would be the worse half.
  # A 422 means the broker already considers it cancelled.
  def take_plan_back
    return if session[:subscription_id].blank?

    account = Account.find_by(pay_subscription_id: session[:subscription_id])

    return unless account&.paid_plan?

    begin
      ContaGorda::Pay::Client.new.cancel_subscription(account.pay_subscription_id, at_period_end: false)
    rescue ContaGorda::Pay::InvalidRequestError
      nil
    end

    end_plan(account)
  end

  # One row per charge, found by the broker's session id, so a refund lands on
  # the payment it refunds. By customer_ref and not by subscription: a renewal
  # of a subscription that has since been replaced is still this customer's
  # money. A charge that was paid keeps its paid_at through a later refund.
  def record_payment(status)
    account = Account.find_by(id: @event.customer_ref)

    return if account.nil? || session[:id].blank?

    payment = Billing::Payment.find_or_initialize_by(pay_session_id: session[:id])

    payment.update!(
      account: account,
      pay_subscription_id: session[:subscription_id],
      status: status,
      description: session.dig(:metadata, :description) || payment.description,
      amount: decimal(session[:amount]),
      refunded_amount: decimal(session[:refunded_amount]),
      currency: session[:currency].to_s.upcase,
      paid_at: payment.paid_at || ((status == "paid") ? @event.created_at || Time.current : nil)
    )
  end

  def decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError
    0
  end

  def time(value)
    Time.zone.parse(value.to_s) if value.present?
  end
end
