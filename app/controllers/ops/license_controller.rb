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

  authorize :manage_account

  def index
    render Views::Ops::License::Index.new(current_path: request.path, servers: all_servers)
  end

  def create
    license = LicenseKey.activate!(params[:license_token], by: Current.user)

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
end
