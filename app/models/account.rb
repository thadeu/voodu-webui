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

  # ── The plan this account bought, on the hosted service ───────────
  #
  # Only consulted when the INSTALLATION is the hosted service. On a
  # self-hosted box the licence on the box says what the operator has, and a
  # per-account plan would be a second answer to the same question.

  # The verified plan licence, or a free one. Never raises: an account whose
  # stored token stopped verifying — key rotated, row corrupted — falls back to
  # free rather than taking the page down, and the screen says so.
  def plan_license
    return @plan_license if defined?(@plan_license)

    @plan_license = resolve_plan_license
  end

  def plan = plan_license.entitled? ? plan_license.plan : LicenseToken::DEFAULT_PLAN

  def pro? = plan == "pro"

  # activate_plan! — store a licence, but only one issued FOR THIS ACCOUNT.
  #
  # The subject check is what stops a plan licence from being a file that
  # circulates: without it, one customer's pro licence pasted into another
  # customer's account would upgrade it. Refused before storing, so a rejected
  # token never sits in the column looking like a plan.
  def activate_plan!(token)
    candidate = LicenseToken.resolve(token.to_s.strip, source: :database)

    return [:invalid, candidate.reason] unless candidate.verified?
    return [:expired, nil] unless candidate.entitled?
    return [:wrong_account, candidate.subject_account] unless candidate.subject_account == short_id

    update!(plan_license_token: token.to_s.strip, plan_activated_at: Time.current)
    @plan_license = candidate

    [:ok, candidate]
  end

  # provision! — an account, its first org, and the owner membership that
  # actually grants access, in one transaction.
  #
  # All three or none. An account with no org is a dead end; an org with no
  # owner membership is an org nobody can open — and because membership is the
  # only source of access, that second one is unrecoverable through the UI.
  #
  # Shared by the two ways a workspace comes into being: a person finishing
  # onboarding (OnboardingsController) and the anonymous operator resolving
  # itself on first request (User.local_operator). Both need identical results,
  # so they read from one definition rather than two that drift.
  def self.provision!(owner:, account_name:, org_name:)
    transaction do
      account = create!(name: account_name, owner: owner)
      org = account.orgs.create!(name: org_name)
      org.memberships.create!(user: owner, role: :owner, status: :active)

      org
    end
  end

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

  private

  def resolve_plan_license
    return LicenseToken.new(status: :none) if plan_license_token.blank?

    license = LicenseToken.resolve(plan_license_token, source: :database)

    # A licence for a different account is not this account's plan, however it
    # got into the column. Checked on READ as well as on write: a row that
    # predates the check, or one written straight to the database, must not
    # grant anything either.
    return LicenseToken.new(status: :none) unless license.subject_account == short_id

    license
  end
end
