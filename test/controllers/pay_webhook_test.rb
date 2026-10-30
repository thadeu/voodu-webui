# frozen_string_literal: true

require "test_helper"

# The webhook is the only thing that grants Pro, so the plan's whole life is
# tested here, through the real endpoint with real signatures — from checkout
# paid to Free again.
class PayWebhookTest < ActionDispatch::IntegrationTest
  include PayTestHelper

  setup do
    sign_out

    @account = accounts(:acme_co)
  end

  def deliver(type, data, id: SecureRandom.uuid)
    body = ContaGorda::Pay::Testing.payload(type, data, id: id)

    post pay_webhook_path, params: body, headers: ContaGorda::Pay::Testing.headers(body)
  end

  def subscription(id: "sub_1", ref: @account.id, **attrs)
    {subscription: {id: id, customer: {external_ref: ref}, metadata: {plan: "pro"}, **attrs}}
  end

  def activate!(id: "sub_1")
    deliver("subscription.activated", subscription(id: id, current_period_end: 30.days.from_now.iso8601))

    assert_response :success
  end

  test "an activated subscription makes the account Pro" do
    activate!

    @account.reload

    assert @account.pro?
    assert_equal "sub_1", @account.pay_subscription_id
    assert_equal "active", @account.pay_status
    assert_in_delta 30.days.from_now, @account.pay_period_end, 5
  end

  # A Pay plan reaches the limits the same way a plan license does, so the
  # rest of the app needs to know nothing about where Pro came from.
  test "the hosted entitlements follow it" do
    hosted = LicenseToken.new(status: :valid, claims: {"sub" => "hosted", "exp" => 1.year.from_now.to_i, "tier" => "unlimited"})

    assert_not Entitlements.for(@account, hosted).pro?

    activate!

    assert Entitlements.for(@account.reload, hosted).pro?
    assert_nil Entitlements.for(@account, hosted).limit(:orgs)
  end

  test "a signature that does not verify changes nothing" do
    body = ContaGorda::Pay::Testing.payload("subscription.activated", subscription)
    headers = ContaGorda::Pay::Testing.headers(body, secret: "pwhsec_somebody_else")

    post pay_webhook_path, params: body, headers: headers

    assert_response :unauthorized
    assert_not @account.reload.pro?
  end

  test "the same event twice is applied once" do
    activate!
    deliver("subscription.canceled", subscription, id: "evt_once")

    assert_not @account.reload.pro?

    @account.update!(pay_status: "active")

    assert_no_difference("PayEvent.count") { deliver("subscription.canceled", subscription, id: "evt_once") }
    assert_response :success
    assert @account.reload.pro?
  end

  test "an activation for some other plan is not Pro" do
    deliver("subscription.activated", {subscription: {id: "sub_1", customer: {external_ref: @account.id}, metadata: {plan: "team"}}})

    assert_not @account.reload.pro?
  end

  test "an activation for an unknown customer is accepted and does nothing" do
    deliver("subscription.activated", subscription(ref: "nobody"))

    assert_response :success
    assert_nil Account.find_by(pay_subscription_id: "sub_1")
  end

  test "a failed renewal keeps Pro while the gateway retries" do
    activate!
    deliver("subscription.past_due", subscription)

    assert_equal "past_due", @account.reload.pay_status
    assert @account.pro?
  end

  test "a renewal moves the period forward" do
    activate!
    deliver("subscription.renewed", subscription(current_period_end: 60.days.from_now.iso8601))

    assert_in_delta 60.days.from_now, @account.reload.pay_period_end, 5
  end

  test "canceling keeps Pro until the end, and resuming takes it back" do
    activate!
    ends = 20.days.from_now.change(usec: 0)

    deliver("subscription.canceling", subscription(cancel_at: ends.iso8601))

    assert_equal "canceling", @account.reload.pay_status
    assert_equal ends, @account.pay_cancel_at
    assert @account.pro?

    deliver("subscription.resumed", subscription)

    assert_equal "active", @account.reload.pay_status
    assert_nil @account.pay_cancel_at
  end

  # The activation of a real checkout carries no period end: the broker
  # learns it from the gateway a moment later and says so with `updated`.
  test "an update fills in the period end the activation did not have" do
    deliver("subscription.activated", subscription(current_period_end: nil))

    assert_nil @account.reload.pay_period_end

    deliver("subscription.updated", subscription(current_period_end: 30.days.from_now.iso8601))

    assert_in_delta 30.days.from_now, @account.reload.pay_period_end, 5
    assert_equal "active", @account.pay_status
  end

  test "an update with a cancel_at is a cancellation scheduled on the gateway" do
    activate!
    ends = 20.days.from_now.change(usec: 0)

    deliver("subscription.updated", subscription(current_period_end: ends.iso8601, cancel_at: ends.iso8601))

    assert_equal "canceling", @account.reload.pay_status
    assert_equal ends, @account.pay_cancel_at
    assert @account.pro?
  end

  test "an update keeps a failed renewal past due" do
    activate!
    deliver("subscription.past_due", subscription)
    deliver("subscription.updated", subscription(current_period_end: 30.days.from_now.iso8601))

    assert_equal "past_due", @account.reload.pay_status
  end

  test "an update for a replaced subscription changes nothing" do
    activate!(id: "sub_old")
    activate!(id: "sub_new")

    deliver("subscription.updated", subscription(id: "sub_old", cancel_at: 1.day.from_now.iso8601))

    assert_equal "active", @account.reload.pay_status
    assert_nil @account.pay_cancel_at
  end

  def charge(type, id: "ses_1", subscription_id: "sub_1", amount: "9.99", **attrs)
    deliver(type, {session: {id: id, status: type.split(".").last, amount: amount, refunded_amount: "0.0",
                             currency: "USD", subscription_id: subscription_id, metadata: {description: "Voodu Pro"},
                             customer: {external_ref: @account.id}, **attrs}})

    assert_response :success
  end

  test "each charge becomes one payment row" do
    charge("session.paid")
    charge("session.paid", id: "ses_2")
    charge("session.failed", id: "ses_3")

    payments = @account.payments.order(:id)

    assert_equal %w[paid paid failed], payments.map(&:status)
    assert_equal BigDecimal("9.99"), payments.first.amount
    assert_equal "USD", payments.first.currency
    assert_equal "sub_1", payments.first.pay_subscription_id
    assert payments.first.paid_at
    assert_nil payments.last.paid_at
  end

  test "a refund lands on the payment it refunds, and keeps when it was paid" do
    charge("session.paid")
    paid_at = @account.payments.sole.paid_at

    charge("session.refunded", refunded_amount: "4.00")

    payment = @account.payments.sole

    assert_equal "refunded", payment.status
    assert payment.partially_refunded?
    assert_equal paid_at, payment.paid_at
  end

  test "a charge for an unknown customer is not recorded" do
    deliver("session.paid", {session: {id: "ses_x", amount: "9.99", currency: "USD", customer: {external_ref: "nobody"}}})

    assert_response :success
    assert_equal 0, Billing::Payment.count
  end

  test "canceled is Free" do
    activate!
    deliver("subscription.canceled", subscription)

    assert_not @account.reload.pro?
    assert_equal "canceled", @account.pay_status
  end

  # The old subscription of an account that subscribed again still sends its
  # own `canceled`. It must not take Pro from the new one.
  test "an event for a replaced subscription changes nothing" do
    activate!(id: "sub_old")
    activate!(id: "sub_new")

    deliver("subscription.canceled", subscription(id: "sub_old"))

    assert @account.reload.pro?
    assert_equal "sub_new", @account.pay_subscription_id
  end

  test "a full refund ends Pro now, cancelled at the broker first" do
    activate!
    cancel = stub_request(:post, "#{PayTestHelper::URL}/api/v1/subscriptions/sub_1/cancel")
      .to_return(status: 200, body: {id: "sub_1", status: "canceled"}.to_json, headers: {"Content-Type" => "application/json"})

    deliver("session.refunded", {session: {id: "ses_1", subscription_id: "sub_1", amount: "9.99", refunded_amount: "9.99", customer: {external_ref: @account.id}}})

    assert_response :success
    assert_requested cancel
    assert_not @account.reload.pro?
  end

  test "a partial refund keeps Pro" do
    activate!
    deliver("session.refunded", {session: {id: "ses_1", subscription_id: "sub_1", amount: "9.99", refunded_amount: "2.00", customer: {external_ref: @account.id}}})

    assert @account.reload.pro?
  end

  # A broker that could not cancel must see a failure and retry: Free here
  # while the card keeps being charged there is the worse half.
  test "a refund whose cancel fails is not marked as applied" do
    activate!
    stub_request(:post, "#{PayTestHelper::URL}/api/v1/subscriptions/sub_1/cancel").to_return(status: 500, body: "{}")

    assert_no_difference("PayEvent.count") do
      assert_raises(ContaGorda::Pay::Error) do
        deliver("session.refunded", {session: {id: "ses_1", subscription_id: "sub_1", amount: "9.99", refunded_amount: "9.99", customer: {external_ref: @account.id}}})
      end
    end

    assert @account.reload.pro?
  end
end
