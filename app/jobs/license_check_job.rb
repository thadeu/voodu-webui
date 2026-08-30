# frozen_string_literal: true

# LicenseCheckJob — the daily look at the stored licence.
#
# Deliberately NOT what makes a licence expire. Status is derived from the clock
# every time it is read (see License#status), so expiry takes effect at the
# second it happens whether or not this job ever runs. A scheduled task that
# "activates" expiry would mean the product was wrong for up to a day, and the
# thing propping it up would be a queue that can fall behind.
#
# What it does earn its place doing:
#
#   - RE-VERIFIES the stored token. It verified when it was pasted, but a public
#     key can change under it on upgrade, and a row can be corrupted. Finding
#     that on a schedule beats finding it when an operator wonders why Settings
#     says Free.
#   - Records last_checked_at, so Settings can show the check is alive rather
#     than leaving the operator guessing.
#   - Warns on approach. The UI banner only appears to whoever opens a page;
#     this lands in the logs an operator greps, on a predictable cadence.
#
# It never writes entitlements, never deletes a key and never changes what is
# in force. Reporting only.
class LicenseCheckJob < ApplicationJob
  queue_as :default

  # How close to expiry each level of noise starts.
  URGENT_WITHIN = 7
  NOTICE_WITHIN = 30

  def perform
    key = Ops::License.current
    return if key.nil?

    license = LicenseToken.current
    key.update_column(:last_checked_at, Time.current)

    report(license)
  end

  private

  def report(license)
    days = license.days_until_expiry

    case license.status
    when :invalid
      Rails.logger.error(
        "[license] the stored licence no longer verifies (#{license.reason}). The " \
        "installation is on the free tier. If the app was upgraded, the signing key " \
        "may have changed — a replacement token is needed."
      )
    when :lapsed
      Rails.logger.warn("[license] #{license.summary}. The installation is on the free tier.")
    when :grace
      Rails.logger.warn(
        "[license] #{license.summary}. Entitlements still apply for " \
        "#{(license.expires_at + LicenseToken::GRACE_PERIOD - Time.current).to_i / 1.day} more days."
      )
    when :valid
      return unless days <= NOTICE_WITHIN

      level = (days <= URGENT_WITHIN) ? :warn : :info
      Rails.logger.public_send(level, "[license] expires in #{days} days — #{license.summary}.")
    end
  end
end
