# frozen_string_literal: true

# Ops::License — an activated licence, stored so renewal does not need a restart.
#
# The upgrade path this exists for: someone runs the free tier, decides they
# want more, buys a licence, pastes the token into Settings, and is Enterprise
# on the next request. No env var, no redeploy, no restarting the dashboard
# their on-call is watching.
#
# One row per activation. The history costs nothing and answers "when did they
# upgrade, and who did it" during a support conversation. The ACTIVE licence is
# whichever has the newest issued_at — see LicenseToken.resolve, where a token in the
# environment competes on the same footing.
#
# Nothing here decides whether a licence is any good. Verification lives in
# LicenseToken and runs against the public key; this only remembers what verified.
class Ops::License < ApplicationRecord
  belongs_to :activated_by, class_name: "User", optional: true

  validates :token, presence: true
  validates :subject, presence: true
  validates :issued_at, :expires_at, presence: true

  scope :newest_first, -> { order(issued_at: :desc, id: :desc) }

  def self.current = newest_first.first

  # activate! — verify first, store only if it verified.
  #
  # Returns the License so the caller can report what was activated. A token
  # that does not verify is NOT stored: a row that never grants anything would
  # sit in Settings looking like a licence and behaving like nothing.
  def self.activate!(token, by: nil)
    license = LicenseToken.resolve(token.to_s.strip)
    return license unless license.verified?

    create!(
      token: license.token,
      subject: license.customer.to_s,
      issued_at: license.issued_at || Time.current,
      expires_at: license.expires_at,
      activated_by: by
    )

    license
  end

  def expired? = expires_at < Time.current
end
