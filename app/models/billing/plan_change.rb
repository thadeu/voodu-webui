# frozen_string_literal: true

# Billing::PlanChange — the owner cancelling Pro from the console, or taking the
# cancellation back.
#
# Both ask the broker first and then write what the broker accepted, so the
# screen is right on the next request. The webhook that follows
# (subscription.canceling / .resumed) writes the same thing again, and is what
# carries the exact cancel_at.
#
# Neither grants anything: a cancel keeps Pro until the end of the paid period,
# and a resume keeps the Pro the account already has. Granting stays with the
# webhook alone.
class Billing::PlanChange
  class NothingToChange < StandardError; end

  def initialize(account:, client: ContaGorda::Pay::Client.new)
    @account = account
    @client = client
  end

  def cancel
    raise NothingToChange unless @account.paid_plan? && @account.pay_status != "canceling"

    @client.cancel_subscription(@account.pay_subscription_id, at_period_end: true)

    @account.update!(pay_status: "canceling", pay_cancel_at: @account.pay_cancel_at || @account.pay_period_end)
  end

  def resume
    raise NothingToChange unless @account.pay_status == "canceling" && @account.pay_subscription_id.present?

    @client.resume_subscription(@account.pay_subscription_id)

    @account.update!(pay_status: "active", pay_cancel_at: nil)
  end
end
