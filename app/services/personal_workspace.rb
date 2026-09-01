# frozen_string_literal: true

# Everybody on the hosted service owns a workspace, from the moment they arrive.
#
# HOSTED ONLY, and the tier is the rule rather than the count. On a self-hosted
# box — free or Enterprise — there is one account and it belongs to whoever
# installed the thing; a workspace appearing around the first stranger who can
# authenticate would consume the very account they were entitled to. A fresh box
# with room to spare still provisions nothing, because the operator should
# choose their own names rather than find a workspace already made.
#
# WHY IT EXISTS. Being invited into somebody else's org used to be the end of
# the road. A membership answered "do you belong to an org?", and that was the
# question guarding onboarding — so a consultant invited into one customer's org
# could never have a workspace of their own. Nobody decided that; two different
# questions shared one answer.
#
# Creating the workspace on arrival settles it without a second question: an
# invitation ADDS to what somebody has, and losing the invitation later leaves
# them holding what was already theirs.
class PersonalWorkspace
  def self.ensure_for(user, license: Current.license)
    new(user, license).ensure!
  end

  def initialize(user, license)
    @user = user
    @license = license
  end

  def ensure!
    return nil unless applicable?

    Account.provision!(owner: @user, account_name: account_name, org_name: account_name)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    # Two tabs, two requests, one arrival. The loser must not take a page down
    # over a workspace the winner already made.
    Rails.logger.info("[workspace] not provisioned for #{@user&.id}: #{e.class}")

    nil
  end

  private

  def applicable?
    return false if @user.nil?
    return false unless @license&.unlimited?

    !@user.owned_accounts.exists?
  end

  # Named after the person, for the account AND its first org, because on a
  # hosted service the account IS the person until they rename it.
  # "mario@x.com" becomes "Mario".
  #
  # The org was called "Default", which is the one name guaranteed to collide:
  # everybody's personal org had it, so an invited admin opened the switcher and
  # saw "Default" twice with no way to tell which was theirs. A name that is
  # unique per person is the whole job here — they can rename it afterwards, and
  # the org switcher now says which account each one belongs to either way.
  def account_name
    # Separators out first: "thadeu.esteves@…" is a very common address shape,
    # and titleize alone leaves "Thadeu.Esteves" — which then names the org too.
    local = @user.email.to_s.split("@").first.to_s.tr("._-", " ").squish.titleize.presence

    local || "My workspace"
  end
end
