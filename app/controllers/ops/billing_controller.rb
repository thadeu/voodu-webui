# frozen_string_literal: true

# Buying Pro from the console, on the hosted service.
#
# The customer clicks Upgrade on the License screen, pays on ContaGorda Pay's
# checkout, and comes back here. Cancel and resume are on the same screen —
# there is no billing portal at the broker, so the console is the only place a
# customer manages their subscription.
#
# What this controller NEVER does is grant the plan. The checkout's return
# carries a signed token, but a browser can replay it until it expires, so it
# chooses the message on the screen and nothing else. Pro starts when the
# webhook says so (Billing::Apply).
#
# Owner-only and hosted-only, for the same reasons as the plan form beside it:
# a plan belongs to the account this person owns, and on a self-hosted box the
# box's own license is the answer.
class Ops::BillingController < ApplicationController
  skip_before_action :require_server!

  authorize_anywhere :manage_account

  before_action :require_billing

  rescue_from ContaGorda::Pay::Error, with: :refuse_broker

  def checkout
    return back(alert: "Your account is already on Pro.") if account.pro?

    url = Billing::Checkout.new(
      account: account,
      email: current_user.email,
      return_to: ops_billing_return_url
    ).redirect_url

    redirect_to url, allow_other_host: true
  end

  # Back from the checkout. The plan has usually not moved yet — the webhook
  # and the browser race, and the browser often wins — so the message says
  # "in a few seconds" rather than "you are on Pro".
  def checkout_return
    claims = ContaGorda::Pay::ReturnToken.new.verify(params[:pay_token], session_id: params[:session_id])

    case claims&.status
    when "paid"
      back(notice: "Payment received. Your plan updates in a few seconds.")
    when "pending", "processing"
      back(notice: "Payment in progress. Your plan updates when it clears.")
    else
      back(alert: "The payment did not go through.")
    end
  rescue ContaGorda::Pay::Error
    back(alert: "The payment did not go through.")
  end

  def cancel
    Billing::PlanChange.new(account: account).cancel

    back(notice: "Your subscription ends at the end of the paid period. Pro stays until then.")
  rescue Billing::PlanChange::NothingToChange
    back(alert: "There is no subscription to cancel.")
  end

  def resume
    Billing::PlanChange.new(account: account).resume

    back(notice: "Your subscription renews as usual.")
  rescue Billing::PlanChange::NothingToChange
    back(alert: "There is no cancellation to take back.")
  end

  private

  def account = plan_account

  # All three, or the screen would offer a button that cannot work: the hosted
  # tier, the broker's key, and an account this person owns.
  def require_billing
    return back(alert: "Plans apply to the hosted service.") unless LicenseToken.current.unlimited?
    return back(alert: "Billing is not available right now.") unless ContaGorda::Pay.configured?

    back(alert: "You do not own an account to put a plan on.") if account.nil?
  end

  def back(**flash) = redirect_to(ops_license_path, **flash)

  # The broker's message stays in the log. The customer gets a sentence they
  # can act on, and nothing about our key or the broker's internals.
  def refuse_broker(error)
    Rails.logger.error("[pay] #{error.class}: #{error.message}")

    back(alert: "Something went wrong with the payment provider. Please try again.")
  end
end
