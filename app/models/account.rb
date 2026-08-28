# frozen_string_literal: true

# Account — the signup tenant. Groups N orgs; an org belongs to exactly one.
#
# An account groups and bills. It does NOT authorize: being in an account
# grants nothing, and reaching an org is always and only an Org::Membership.
# Keeping that rule absolute is what lets cross-account access — being invited
# into another company's org — work with no exception anywhere, and it means a
# scoping mistake can expose at most one org rather than a whole account.
class Account < ApplicationRecord
  include HasUuidV7
  include UniqueShortKeyable

  unique_short_key :short_id, length: 8

  # The principal: who signed up, who answers for the account, and who no admin
  # can remove. restrict_with_error on the user side (see User) keeps a person
  # who still owns an account from being deleted out from under it.
  belongs_to :owner, class_name: "User"

  has_many :orgs, dependent: :restrict_with_error

  validates :name, presence: true, length: {maximum: 64}
  validates :short_id, presence: true, uniqueness: true, format: {with: /\A[a-zA-Z0-9]{8}\z/}

  def to_param = short_id

  # transfer_to! — hand the account to someone else.
  #
  # The new owner must already hold an ACTIVE membership in every org of this
  # account. Handing it to someone who reaches none of them produces exactly the
  # state the last-privileged-member guard exists to prevent: a principal on
  # paper who cannot open anything, and orgs whose servers keep being polled
  # with live PATs while nobody can turn them off.
  #
  # Ownership is a fact about responsibility, not a grant — so this changes who
  # answers for the account and nothing about who reaches what.
  def transfer_to!(new_owner)
    raise ArgumentError, "the new owner must be a User" unless new_owner.is_a?(User)
    return true if new_owner == owner

    unreachable = orgs.reject { |org| new_owner.membership_in(org)&.privileged? }

    if unreachable.any?
      raise ArgumentError,
        "#{new_owner.email} is not an admin or owner of #{unreachable.map(&:name).to_sentence}"
    end

    update!(owner: new_owner)
  end
end
