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

  # A migration is outstanding while an address was named and nobody has
  # claimed it yet.
  def pending_migration? = pending_owner_email.present? && migrated_at.nil?

  # claimable_by? — may THIS person take the workspace?
  #
  # The address must match and must be proven. An unverified address is not
  # identity: a provider that lets someone assert an arbitrary email would
  # otherwise hand over an entire installation.
  def claimable_by?(user)
    return false unless pending_migration?
    return false unless user&.verified_email?

    user.email.to_s.casecmp?(pending_owner_email.to_s)
  end

  # migrate_to! — move the anonymous operator's workspace onto a real identity.
  #
  # Memberships first, then the accounts they own: Account#transfer_to! refuses
  # an owner who does not already hold a privileged membership in every org of
  # the account, which is the guard that stops an account being handed to
  # somebody who cannot open any of it. Doing it in this order satisfies that
  # rather than working around it.
  def migrate_to!(user)
    operator = User.find_by(email: User::LOCAL_OPERATOR_EMAIL)

    transaction do
      if operator && operator != user
        operator.org_memberships.find_each { |m| m.update!(user: user) }
        operator.owned_accounts.reload.find_each { |account| account.transfer_to!(user) }
      end

      update!(migrated_at: Time.current)
    end

    user
  end
end
