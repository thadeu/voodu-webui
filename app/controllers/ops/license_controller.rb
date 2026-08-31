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

  def refuse_unlimited
    redirect_to back_to_settings,
      alert: "This installation runs on a hosted plan. Its licence is managed by whoever " \
             "operates it, not from here."
  end
end
