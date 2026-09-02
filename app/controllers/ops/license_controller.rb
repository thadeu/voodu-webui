# frozen_string_literal: true

# Activating an Enterprise licence from Settings.
#
# The upgrade path this serves: someone runs the free tier, buys a licence, is
# sent a token, pastes it here, and is Enterprise on the very next request — no
# env var, no redeploy, no restarting the dashboard their on-call is watching.
#
# Owner-only. It is the commercial state of the whole installation, which is the
# same bracket as the account itself.
class Ops::LicenseController < ApplicationController
  skip_before_action :require_server!

  authorize_anywhere :manage_account

  def index
    render Views::Ops::License::Index.new(current_path: request.path, servers: sidebar_servers)
  end

  # Refused only on the hosted service, whose licence belongs to whoever runs
  # the box rather than to the customer reading the screen.
  #
  # NOT refused merely because the environment supplied it. An operator whose
  # env licence expires buys a newer one and pastes it here — precedence is by
  # issue date, so the newer one wins — and locking the form would have removed
  # it at exactly the moment it was needed.
  def create
    # Two forms post here, and they mean different things. A plan licence
    # belongs to ONE account; the installation's belongs to the box. Routing on
    # a hidden field rather than on two endpoints keeps the screen's two
    # sections obviously the same action with different scope.
    return activate_plan if params[:scope] == "plan"

    return refuse_unlimited if LicenseToken.current.unlimited?

    license = Ops::License.activate!(params[:license_token], by: Current.user)

    if license.verified?
      redirect_to back_to_settings, notice: "Licence activated — #{license.summary}."
    else
      redirect_to back_to_settings, alert: refusal_for(license)
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to back_to_settings, alert: e.record.errors.full_messages.to_sentence
  end

  private

  # A refused token is nearly always a paste accident, so say which kind.
  def refusal_for(license)
    return "Paste the licence token you were sent." if license.status == :none

    "That licence could not be verified (#{license.reason}). Check it was pasted " \
      "whole — the token is one long line with no spaces."
  end

  # Settings is server-scoped and this route is not, so there is no server in
  # scope here to rebuild the URL from. The form carries where it came from and
  # Returnable validates it — the same guard the alert modal uses, which is what
  # keeps an attacker-supplied return_to from becoming an open redirect.
  def back_to_settings = return_to_path(ops_license_path)

  # The customer's own plan, on the hosted service. Refused anywhere else: on a
  # self-hosted box the licence on the box already says what they have, and a
  # second answer could only disagree with it.
  def activate_plan
    return refuse_not_hosted unless LicenseToken.current.unlimited?

    # plan_account, not the visited org's. /ops/license takes no :org_id at all,
    # so `current_org&.account` was nil on every direct visit and this refused
    # with "No account in scope" — and when it was NOT nil, it was somebody
    # else's account, reachable by any invited admin.
    account = plan_account
    return redirect_to(back_to_settings, alert: "You do not own an account to put a plan on.") if account.nil?

    status, detail = account.activate_plan!(params[:license_token])

    redirect_to back_to_settings, **plan_result(status, detail, account)
  end

  def plan_result(status, detail, account)
    case status
    when :ok
      {notice: "Plan activated — #{account.reload.plan.capitalize}."}
    when :not_a_plan
      {alert: "That licence is for an installation (#{detail}), not for a plan. " \
              "Ask for a plan licence issued for account #{account.short_id}."}
    when :wrong_account
      {alert: "That licence was issued for account #{detail}, not for #{account.short_id}."}
    when :expired
      {alert: "That licence has expired. Ask for a current one."}
    else
      {alert: "That licence could not be verified#{" (#{detail})" if detail.present?}."}
    end
  end

  def refuse_not_hosted
    redirect_to back_to_settings,
      alert: "Plans apply to the hosted service. This installation is governed by its own licence."
  end

  def refuse_unlimited
    redirect_to back_to_settings,
      alert: "This installation runs on a hosted plan. Its licence is managed by whoever " \
             "operates it, not from here."
  end
end
