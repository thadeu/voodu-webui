# frozen_string_literal: true

class Org
  # Org::Membership — the ONLY thing that grants access to an org.
  #
  # An invitation is a membership with `status: invited`: same row, same unique
  # index, one place that knows who may be here. `active` is what authorization
  # reads — an invitation that was never accepted must never put someone inside
  # the org.
  #
  # Roles are ordered (member < admin < owner) and Permissions compares against
  # the minimum a capability needs, so a new capability is one table entry
  # rather than a role list repeated at every call site.
  class Membership < ApplicationRecord
    include HasUuidV7

    self.table_name = "org_memberships"

    belongs_to :user
    belongs_to :org

    has_many :server_accesses, class_name: "Org::ServerAccess",
      foreign_key: :membership_id, dependent: :destroy, inverse_of: :membership

    # validate: true makes a bogus value an ActiveModel error rather than an
    # ArgumentError raise — a forged form field must not 500.
    enum :role, {member: 0, admin: 1, owner: 2}, default: :member, validate: true
    enum :status, {invited: 0, active: 1}, default: :invited, validate: true

    validates :user_id, uniqueness: {scope: :org_id}

    scope :privileged, -> { where(role: [:admin, :owner]) }

    before_destroy :refuse_removing_last_privileged_member
    validate :refuse_demoting_last_privileged_member, on: :update

    def privileged? = admin? || owner?

    # The invite link is the membership's signed id: no token column, nothing
    # to leak from the database, and it expires on its own. Purpose-scoped so a
    # signed id minted for anything else cannot be replayed here.
    INVITE_MAX_AGE = 30.days

    def invite_token
      signed_id(purpose: :invite, expires_in: INVITE_MAX_AGE)
    end

    def self.find_invited(token)
      find_signed(token, purpose: :invite)
    end

    private

    # An org whose last admin-or-owner leaves is unreachable BY ANYONE:
    # membership is the only source of access, and the account owner's title
    # grants nothing by itself. Its servers keep being polled with live PATs and
    # nobody can turn them off. Refuse instead.
    def refuse_removing_last_privileged_member
      # The org itself is going away — there is nothing left to be locked out
      # of, and refusing here would make an org undeletable by construction.
      return if destroyed_by_association
      return unless privileged?
      return if org.memberships.active.privileged.where.not(id: id).exists?

      errors.add(:base, "an org must keep at least one active admin or owner")
      throw :abort
    end

    def refuse_demoting_last_privileged_member
      return unless role_previously_was_privileged? && !privileged?
      return if org.memberships.active.privileged.where.not(id: id).exists?

      errors.add(:role, "would leave the org with no admin or owner")
    end

    def role_previously_was_privileged?
      return false unless role_changed?

      %w[admin owner].include?(role_was.to_s)
    end
  end
end
