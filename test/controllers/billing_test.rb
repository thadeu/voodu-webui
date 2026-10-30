# frozen_string_literal: true

require "test_helper"

# Buying Pro from the console: the button, the checkout, the way back, and
# cancel/resume. None of these may grant the plan — that is the webhook's
# alone (PayWebhookTest) — so every test here also checks that it did not.
class BillingTest < ActionDispatch::IntegrationTest
  include PayTestHelper

  HOSTED = LicenseToken.new(
    status: :valid,
    claims: {"sub" => "hosted", "exp" => 1.year.from_now.to_i, "tier" => "unlimited"}
  )

  # Bare, as the browser asks for it — see HostedInstallationChromeTest for why
  # the path helper would add an org to the query string.
  LICENSE = "/ops/license"

  setup do
    @installed = Rails.application.config.x.license
    Rails.application.config.x.license = HOSTED

    sign_in_as(email: users(:owner).email)

    @account = accounts(:acme_co)
  end

  teardown { Rails.application.config.x.license = @installed }

  def checkout_stub(url: "https://pay.test/c/ses_1")
    stub_request(:post, "#{PayTestHelper::URL}/connect")
      .to_return(status: 200, body: {id: "ses_1", redirect_url: url}.to_json, headers: {"Content-Type" => "application/json"})
  end

  def paid!(status: "active")
    @account.update!(pay_subscription_id: "sub_1", pay_status: status, pay_period_end: 20.days.from_now)
  end

  test "a Free account is offered the upgrade at the configured price" do
    get LICENSE

    assert_response :success
    assert_select "form[action^='/ops/billing/checkout'][data-turbo='false']"
    assert_includes response.body, "Upgrade to Pro — $9.99/mo"
  end

  test "no upgrade button when the broker is not configured" do
    pay_unconfigured!

    get LICENSE

    assert_select "form[action^='/ops/billing/checkout']", 0
  end

  test "checkout sends the owner to the broker and grants nothing" do
    checkout_stub

    post ops_billing_checkout_path

    assert_redirected_to "https://pay.test/c/ses_1"
    assert_requested(:post, "#{PayTestHelper::URL}/connect") do |request|
      body = JSON.parse(request.body)

      body["amount"] == "9.99" && body["currency"] == "USD" && body["interval"] == "month" &&
        body.dig("customer", "external_ref") == @account.id && body.dig("metadata", "plan") == "pro"
    end
    assert_not @account.reload.pro?
  end

  test "PRO_PLAN_PRICE changes what the checkout charges" do
    checkout_stub

    ENV["PRO_PLAN_PRICE"] = "19"
    post ops_billing_checkout_path

    assert_requested(:post, "#{PayTestHelper::URL}/connect") { |request| JSON.parse(request.body)["amount"] == "19.00" }
  ensure
    ENV.delete("PRO_PLAN_PRICE")
  end

  test "a checkout answer without an https URL is refused" do
    checkout_stub(url: "http://evil.test/")

    post ops_billing_checkout_path

    assert_redirected_to ops_license_path
    assert_match(/payment provider/i, flash[:alert])
  end

  test "an account already on Pro is not sent to pay again" do
    paid!

    post ops_billing_checkout_path

    assert_redirected_to ops_license_path
    assert_match(/already on Pro/i, flash[:alert])
  end

  test "checkout is refused off the hosted service" do
    Rails.application.config.x.license = @installed

    post ops_billing_checkout_path

    assert_redirected_to ops_license_path
    assert_match(/hosted service/i, flash[:alert])
  end

  test "the return says paid, and the plan still waits for the webhook" do
    token = ContaGorda::Pay::Testing.return_token(session_id: "ses_1", status: "paid")

    get ops_billing_return_path(session_id: "ses_1", pay_token: token)

    assert_redirected_to ops_license_path
    assert_match(/payment received/i, flash[:notice])
    assert_not @account.reload.pro?
  end

  test "a forged return token says the payment did not go through" do
    token = ContaGorda::Pay::Testing.return_token(session_id: "ses_1", status: "paid", secret_key: "sk_app_test_other")

    get ops_billing_return_path(session_id: "ses_1", pay_token: token)

    assert_match(/did not go through/i, flash[:alert])
  end

  test "cancel asks the broker and keeps Pro until the end" do
    paid!
    stub_request(:post, "#{PayTestHelper::URL}/api/v1/subscriptions/sub_1/cancel")
      .to_return(status: 200, body: {id: "sub_1"}.to_json, headers: {"Content-Type" => "application/json"})

    post ops_billing_cancel_path

    assert_requested(:post, "#{PayTestHelper::URL}/api/v1/subscriptions/sub_1/cancel") { |request| JSON.parse(request.body)["at_period_end"] == true }
    assert_equal "canceling", @account.reload.pay_status
    assert @account.pro?
  end

  test "resume takes the cancellation back" do
    paid!(status: "canceling")
    resume = stub_request(:post, "#{PayTestHelper::URL}/api/v1/subscriptions/sub_1/resume")
      .to_return(status: 200, body: {id: "sub_1"}.to_json, headers: {"Content-Type" => "application/json"})

    post ops_billing_resume_path

    assert_requested resume
    assert_equal "active", @account.reload.pay_status
  end

  test "nothing to cancel without a subscription" do
    post ops_billing_cancel_path

    assert_match(/no subscription to cancel/i, flash[:alert])
  end

  test "the owner sees the payments of their subscription, newest first" do
    paid!
    @account.payments.create!(pay_session_id: "ses_1", status: "paid", amount: "9.99", currency: "USD",
      paid_at: 40.days.ago, created_at: 40.days.ago)
    @account.payments.create!(pay_session_id: "ses_2", status: "failed", amount: "9.99", currency: "USD")

    get LICENSE

    assert_includes response.body, "Payments"
    assert_includes response.body, "USD 9.99"
    assert_includes response.body, "declined"
    assert_operator response.body.index("declined"), :<, response.body.index(40.days.ago.to_date.to_s)
  end

  test "no payments section before the first charge" do
    get LICENSE

    assert_not_includes response.body, ">Payments<"
  end

  test "the screen offers the one action that applies" do
    paid!

    get LICENSE

    assert_select "form[action^='/ops/billing/cancel']"
    assert_select "form[action^='/ops/billing/resume']", 0
    assert_includes response.body, "renews #{20.days.from_now.to_date}"

    @account.update!(pay_status: "canceling", pay_cancel_at: 20.days.from_now)
    get LICENSE

    assert_select "form[action^='/ops/billing/resume']"
    assert_select "form[action^='/ops/billing/cancel']", 0
  end

  # The plan is always the account this person OWNS, never the one behind the
  # org in the URL: an admin invited into another company's org must not buy,
  # or cancel, a plan for it.
  test "checkout is for the account the person owns, whatever org is in scope" do
    email = "guest-#{SecureRandom.hex(3)}@example.com"
    sign_in_as(email: email)

    checkout_stub
    post "/ops/billing/checkout?org_id=#{orgs(:acme).short_id}"

    # Made on arrival, by the request above — so looked up after it.
    own = User.find_by!(email: email).owned_accounts.first

    assert_not_equal orgs(:acme).account_id, own.id
    assert_requested(:post, "#{PayTestHelper::URL}/connect") do |request|
      JSON.parse(request.body).dig("customer", "external_ref") == own.id
    end
  end
end
