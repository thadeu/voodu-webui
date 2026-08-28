# frozen_string_literal: true

# User — the local mirror of a Clowk subject.
#
# Clowk answers exactly one question: who is this person. Everything above it —
# which orgs they reach, with what role, over which servers — is ours, and hangs
# off this row. Nothing here is a credential: the token is verified by the gem
# on every sign-in, and this table holds only what the claims already carry.
#
# Identity is keyed on `clowk_user_id` (the token's `sub`, stable and unique),
# never on the email address. The address is a MIRROR and is not editable: make
# it editable and it becomes a credential someone can forge — set it to an
# address you do not own, wait for that address to be invited somewhere, and the
# invitation binds to your row.
class User < ApplicationRecord
  include HasUuidV7

  # Clowk substitutes a synthetic address when the provider hands back no email
  # (GitHub with a private address, Apple after the first authorization). These
  # satisfy the email format check, so validation will never catch them — every
  # place that treats an address as identity has to ask instead.
  PLACEHOLDER_EMAIL_SUFFIX = "@clowk.noemail"

  has_many :org_memberships, class_name: "Org::Membership", dependent: :destroy, inverse_of: :user
  has_many :orgs, through: :org_memberships

  # restrict: deleting someone who still answers for an account would leave it
  # ownerless, and an account with no principal is one nobody can wind down.
  has_many :owned_accounts, class_name: "Account", foreign_key: :owner_id,
    dependent: :restrict_with_error, inverse_of: :owner

  normalizes :email, with: ->(value) { value.to_s.strip.downcase.presence }

  validates :email, presence: true, uniqueness: true,
    format: {with: URI::MailTo::EMAIL_REGEXP}

  # An address is usable as identity only once someone has proven it. Used
  # wherever we would otherwise treat "same string" as "same person".
  def verified_email?
    email_verified? && !placeholder_email?
  end

  def placeholder_email?
    email.to_s.end_with?(PLACEHOLDER_EMAIL_SUFFIX)
  end

  def display_name
    name.presence || email
  end

  # The orgs this person may actually act in. `orgs` traverses EVERY membership
  # including invited ones, so it answers "was this person ever asked", not "may
  # they be here". Authorization must use this one, or an invitation nobody
  # accepted puts someone inside the org.
  def active_orgs
    orgs.merge(Org::Membership.active)
  end

  def membership_in(org)
    return nil if org.nil?

    org_memberships.active.find_by(org_id: org.id)
  end

  # provision_from_clowk! — find or build the row for a verified token's claims.
  #
  # The three rules here are the whole security story of this class:
  #
  #   1. Key on `sub`. It is the only stable, unique identifier in the token.
  #   2. Claim an existing row by email ONLY when that row is still unbound
  #      (clowk_user_id nil) AND the address is proven. Without both conditions
  #      a provider that lets someone assert an arbitrary address is an account
  #      takeover: sign up claiming a stranger's address, get handed their row.
  #   3. Never let a placeholder address claim or overwrite anything. Two
  #      subjects can arrive holding the same one, so ours is derived from
  #      `sub`, which cannot collide.
  def self.provision_from_clowk!(claims)
    clowk_id = claims[:sub].presence
    raise ArgumentError, "clowk claims missing sub" if clowk_id.blank?

    email = claims[:email].to_s.strip.downcase.presence
    real_email = email.present? && !email.end_with?(PLACEHOLDER_EMAIL_SUFFIX)
    verified = claims[:email_verified] == true

    user = find_by(clowk_user_id: clowk_id)
    user ||= claimable_row(email) if real_email && verified
    user ||= new(email: address_for_new_row(email, verified: verified, subject: clowk_id))

    user.clowk_user_id = clowk_id
    user.clowk_provider = claims[:provider].presence || user.clowk_provider
    user.name ||= claims[:name].presence
    user.avatar_url = claims[:avatar_url].presence || user.avatar_url
    user.email_verified = verified
    user.last_signed_in_at = Time.current
    # Refresh the mirrored address on an EXISTING row only. A new row already
    # got its address from address_for_new_row, and overwriting that would undo
    # the one decision that keeps an unproven subject off somebody else's
    # invitation. Never overwrite a genuine address with a placeholder.
    user.email = email if real_email && user.persisted?

    user.save!
    user
  rescue ActiveRecord::RecordNotUnique
    # Two concurrent first sign-ins raced on the unique index. The winner's row
    # is authoritative.
    find_by!(clowk_user_id: clowk_id)
  rescue ActiveRecord::RecordInvalid => e
    # A different local row already holds this address. Refusing is the safe
    # outcome — the alternative hands one person another's account.
    Rails.logger.error("[auth] cannot provision clowk subject #{clowk_id}: #{e.message}")
    raise
  end

  # The address a BRAND NEW row may take.
  #
  #   proven          → the claimed address. If another row already holds it,
  #                     that row belongs to a different subject and saving
  #                     collides on purpose: refusing beats handing one person
  #                     another's account.
  #   unproven, free  → the claimed address. Nobody is contesting it, and
  #                     email_verified stays false so nothing treats it as
  #                     identity.
  #   unproven, taken → a synthetic address derived from `sub`. This is the
  #                     invited-row case: we will not claim it, but we must not
  #                     crash this person's sign-in over an address they merely
  #                     asserted either. They get their own row; the invitation
  #                     keeps waiting for whoever can prove the address.
  #   none            → synthetic, always. Two subjects can arrive holding the
  #                     same placeholder, so ours is derived from `sub`.
  def self.address_for_new_row(email, verified:, subject:)
    synthetic = "#{subject}#{PLACEHOLDER_EMAIL_SUFFIX}"
    return synthetic if email.blank? || email.end_with?(PLACEHOLDER_EMAIL_SUFFIX)
    return email if verified || !exists?(email: email)

    synthetic
  end
  private_class_method :address_for_new_row

  # An invited row waiting to be claimed: the address matches and nobody has
  # bound a Clowk subject to it yet. A row that IS bound belongs to someone
  # else, whatever address the incoming claims assert.
  def self.claimable_row(email)
    candidate = find_by(email: email)

    candidate if candidate && candidate.clowk_user_id.nil?
  end
  private_class_method :claimable_row
end
