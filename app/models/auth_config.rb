# frozen_string_literal: true

# AuthConfig — Clowk credentials entered through Settings.
#
# The second thing this installation can buy. A free-tier operator behind a VPN
# may decide they want real per-person sign-in; they pay for a Clowk instance,
# paste its publishable key here, and the app starts authenticating against it —
# no env var, no redeploy.
#
# THE ENVIRONMENT ALWAYS WINS. That is not a precedence preference, it is the
# way out: a wrong publishable key saved here would send every request to a
# Clowk instance that does not know the operator, locking them out of their own
# dashboard with no UI left to fix it from. Restarting with CLOWK_ENABLED=0
# always returns them to anonymous mode, whatever this table says.
class AuthConfig < ApplicationRecord
  encrypts :secret_key_ciphertext

  belongs_to :configured_by, class_name: "User", optional: true

  # Clowk derives the sign-in URL, the JWKS endpoint and the token audience from
  # this, so a malformed one is not a setting, it is an outage.
  validates :publishable_key, presence: true, format: {
    with: /\Apk_[a-zA-Z0-9_]+\z/, message: "should look like pk_live_… or pk_test_…"
  }
  validates :subdomain_url, allow_blank: true, format: {
    with: %r{\Ahttps://[^\s/]+\z}, message: "should be an https URL with no path"
  }

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def self.current = newest_first.first

  alias_attribute :secret_key, :secret_key_ciphertext
end
