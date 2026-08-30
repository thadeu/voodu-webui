# frozen_string_literal: true

# SsoConfiguration — which identity provider this installation trusts, and how
# to reach it.
#
# The second thing an installation can pay for. A free-tier operator running
# behind a VPN decides they want per-person identity, buys it, and configures it
# here without a redeploy.
#
# Shaped around `provider` + `settings` rather than one provider's columns.
# Clowk is the only one today and `publishable_key` is Clowk's word for it — a
# schema built on that would need either columns that are null for everyone else
# or a second table saying the same thing differently. Settings live in JSON
# because nothing queries them: they are read whole and handed to whatever they
# configure. (The metrics warehouse went the other way for the opposite reason —
# those columns exist to be indexed.)
#
# One row per change. For an authentication setting, "who turned this on and
# when" is worth more than for most things.
class SsoConfiguration < ApplicationRecord
  PROVIDERS = %w[clowk].freeze

  # Public identifiers, per provider. Adding one means a new key here and a
  # branch in AuthSettings#apply! — not a migration.
  store_accessor :settings, :publishable_key, :subdomain_url

  encrypts :secret_ciphertext

  belongs_to :configured_by, class_name: "User", optional: true

  validates :provider, presence: true, inclusion: {in: PROVIDERS}
  validates :publishable_key, presence: true

  # Provider-specific, and scoped as such: pk_ is what Clowk issues, and
  # asserting it of a provider that spells its keys differently would be a bug
  # the day the second one arrives.
  validates :publishable_key, format: {
    with: /\Apk_[a-zA-Z0-9_]+\z/, message: "should look like pk_live_… or pk_test_…"
  }, if: :clowk?

  validates :subdomain_url, allow_blank: true, format: {
    with: %r{\Ahttps://[^\s/]+\z}, message: "should be an https URL with no path"
  }

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def self.current = newest_first.first

  def clowk? = provider == "clowk"

  alias_attribute :secret_key, :secret_ciphertext

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
