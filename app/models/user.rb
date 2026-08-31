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
  # The anonymous operator's address. Not a mailbox and not identity — a stable
  # handle for the single row every request runs as when CLOWK_ENABLED is off.
  # `email_verified` stays false, so verified_email? is false and nothing that
  # treats an address as proof of a person (invitations, session revocation)
  # ever matches it.
  LOCAL_OPERATOR_EMAIL = "free@voodu.clowk.in"

  # What this address used to be. An installation that ran an earlier build
  # already holds a workspace under it — its org, its servers, its PATs, its
  # licence history. Looking only for the current address would find none of
  # that, provision a SECOND operator beside it, and strand the first behind a
  # sign-in that anonymous mode never shows. So the old address is adopted, not
  # ignored, and the row is renamed in place the first time it is seen.
  LEGACY_LOCAL_OPERATOR_EMAILS = ["operator@voodu.local"].freeze

  # The name shown wherever this row is displayed as a person. "Free Tier"
  # rather than "Local operator" because it answers the question someone
  # actually has when they open the account menu — which plan am I on — and the
  # address beside it already says the account is a local one.
  LOCAL_OPERATOR_NAME = "Free Tier"
  LEGACY_LOCAL_OPERATOR_NAMES = ["Local operator"].freeze

  # local_operator — the identity behind every request in anonymous mode.
  #
  # NOT a bypass. This is a real row with a real owner membership, so
  # authorization keeps running through the one path it always runs through:
  # there is simply exactly one membership to find. Nothing downstream learns
  # that sign-in was skipped, which is the property that keeps anonymous mode
  # from becoming a second way to reach a server.
  #
  # Idempotent under a race. Two Puma workers can take a first request at the
  # same instant; both would find nothing and both would create. The unique
  # index on `email` is the serialisation point, and the workspace is built in
  # the SAME transaction — so the loser's account and org roll back with its
  # user instead of leaving a second orphan workspace behind.
  def self.local_operator
    existing = find_by(email: LOCAL_OPERATOR_EMAIL) || find_by(email: LEGACY_LOCAL_OPERATOR_EMAILS)
    return repair_local_workspace(carry_forward_identity(existing)) if existing

    create_local_operator!
  end

  # Both the seeded address and the seeded name have changed since earlier
  # builds. They are corrected ON THE ROW THAT ALREADY EXISTS rather than by
  # creating a new one: the whole workspace — the org, its servers, their PATs,
  # the licence history — hangs off this row, and a second operator beside it
  # would strand all of it behind a sign-in that anonymous mode never shows.
  #
  # Only values this code seeded are replaced, so anything a later feature sets
  # deliberately survives. The current address is looked up FIRST, so if both
  # somehow exist the current row wins and the legacy one is left untouched:
  # merging two workspaces is not something to attempt inside a request.
  def self.carry_forward_identity(user)
    changes = {}
    changes[:email] = LOCAL_OPERATOR_EMAIL if LEGACY_LOCAL_OPERATOR_EMAILS.include?(user.email)
    changes[:name] = LOCAL_OPERATOR_NAME if LEGACY_LOCAL_OPERATOR_NAMES.include?(user.name)
    return user if changes.empty?

    user.update!(**changes)
    Rails.logger.info("[auth] local operator identity carried forward: #{changes.keys.join(", ")}")

    user
  end
  private_class_method :carry_forward_identity

  def self.create_local_operator!
    transaction do
      user = create!(email: LOCAL_OPERATOR_EMAIL, name: LOCAL_OPERATOR_NAME, email_verified: false)
      Account.provision!(owner: user, account_name: "Local", org_name: "Default")

      user
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    # Another worker won. Its workspace is committed; ours rolled back whole.
    #
    # Both exceptions are the same race seen at different depths: the uniqueness
    # VALIDATION catches it when the winner committed before our SELECT, the
    # unique INDEX catches it when the winner committed between our SELECT and
    # our INSERT. Re-raise anything that is not that race, or a genuine failure
    # would be swallowed and reported as a missing operator.
    existing = find_by(email: LOCAL_OPERATOR_EMAIL)
    raise e if existing.nil?

    repair_local_workspace(existing)
  end
  private_class_method :create_local_operator!

  # Only reachable if the workspace was destroyed out from under the operator
  # (someone deleted the org). Without this the app would answer every page with
  # "you belong nowhere" and offer onboarding, which anonymous mode does not show.
  def self.repair_local_workspace(user)
    return user if user.active_orgs.exists?

    Account.provision!(owner: user, account_name: "Local", org_name: "Default")

    user
  end
  private_class_method :repair_local_workspace

  def self.provision_from_clowk!(claims)
    clowk_id = claims[:sub].presence
    raise ArgumentError, "clowk claims missing sub" if clowk_id.blank?

    email = claims[:email].to_s.strip.downcase.presence
    real_email = email.present? && !email.end_with?(PLACEHOLDER_EMAIL_SUFFIX)
    verified = claims[:email_verified] == true

    user = find_by(clowk_user_id: clowk_id)
    user ||= row_for_verified_address(email) if real_email && verified
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

  # The row that owns a VERIFIED address — invited, or already signed in.
  #
  # A verified address is the identity. Somebody who signs up with Google and
  # later signs in with GitHub on the same address is one person, and the two
  # providers hand us two different subjects; treating those as two accounts
  # meant the second sign-in tried to insert a duplicate address and died with
  # "Email has already been taken". On a service with open sign-up that is not
  # an edge case, it is a Tuesday.
  #
  # So the subject follows the address: the row is found by email and its
  # clowk_user_id is rebound to whichever provider was used this time. Safe
  # because nothing else in the app keys off that column — it is the lookup
  # handle, not an identifier anything stores.
  #
  # VERIFIED is doing the work. An unverified address is an assertion, not a
  # fact, and matching on one would let anyone who can get a provider to echo
  # an address walk into that person's orgs. Callers check it before asking.
  def self.row_for_verified_address(email)
    find_by(email: email)
  end
  private_class_method :row_for_verified_address
end
