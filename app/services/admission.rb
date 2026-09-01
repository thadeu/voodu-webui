# frozen_string_literal: true

# Admission — may this verified identity have a row on this installation?
#
# Signing in proves who somebody IS. It says nothing about whether they belong
# here, and without a second question every identity a Clowk instance will
# authenticate gets a user row on the box. Those rows reach nothing —
# membership is the only source of access — but they accumulate invisibly,
# because a row in no org appears on no screen.
#
# The invite list is the allowlist. It is already curated by the people who
# know, already keyed on the address, and already how somebody legitimately
# arrives; a second list beside it could only disagree with it.
#
# FOUR reasons to be let in, and the last one is what keeps this from bricking
# the product:
#
#   1. an active membership — they are already inside
#   2. an INVITED membership — somebody with the authority asked them here
#   3. the sign-in handover named them — the anonymous workspace is theirs to
#      claim, and refusing would strand every server and token in it
#   4. the installation has room for another account — which is what "open
#      sign-up" means, and is true of a fresh box and of the hosted service
#
# Without (4) a freshly installed box with sign-in already on would let nobody
# in at all, including the operator who just installed it, and the hosted
# service could never take a customer.
#
# Reason (4) reuses the predicate that governs onboarding rather than
# introducing a second rule. One question decides both doors, so they cannot
# drift into disagreeing about who may start a workspace.
class Admission
  Decision = Struct.new(:allowed, :reason) do
    def allowed? = allowed == true
  end

  ALLOWED = %i[member invited claiming_workspace open_signup].freeze

  # claims — the verified Clowk claims. Only a VERIFIED address may match an
  # invitation: an unverified one is an assertion, and matching on it would let
  # anybody who can get a provider to echo an address walk into the org that
  # address was invited to.
  def self.decide(claims, entitlements: Entitlements.for(nil))
    new(claims, entitlements).decide
  end

  def initialize(claims, entitlements)
    @claims = claims || {}
    @entitlements = entitlements
  end

  def decide
    return allow(:member) if known_subject? || active_membership?
    return allow(:invited) if invited?
    return allow(:claiming_workspace) if claiming_workspace?
    return allow(:open_signup) if @entitlements.room_for_another_account?

    Decision.new(false, :no_invitation)
  end

  private

  def allow(reason) = Decision.new(true, reason)

  def subject = @claims[:sub].presence || @claims["sub"].presence

  def email
    address = (@claims[:email] || @claims["email"]).to_s.strip.downcase

    address.presence
  end

  def verified? = (@claims[:email_verified] || @claims["email_verified"]) == true

  # Somebody who has signed in here before. Checked first and on the subject
  # rather than the address, so an existing operator is never re-evaluated
  # against a list they predate.
  def known_subject?
    subject.present? && User.exists?(clowk_user_id: subject)
  end

  def existing_user
    return @existing_user if defined?(@existing_user)

    @existing_user = (User.find_by(email: email) if email && verified?)
  end

  def active_membership? = existing_user&.org_memberships&.active&.exists? || false

  def invited?
    existing_user&.org_memberships&.where(status: :invited)&.exists? || false
  end

  # The anonymous→Clowk handover. This person has no membership and no
  # invitation by construction — the workspace they are coming to claim is
  # owned by the local operator, and the handover happens after they sign in.
  def claiming_workspace?
    return false if email.nil? || !verified?

    Ops::SsoConfig.current&.claimable_by?(candidate_for_claim) || false
  rescue ActiveRecord::ActiveRecordError
    false
  end

  # claimable_by? asks for a verified address, which is all it reads. A user
  # row may not exist yet, so a stand-in carries the claims.
  def candidate_for_claim
    existing_user || User.new(email: email, email_verified: verified?)
  end
end
