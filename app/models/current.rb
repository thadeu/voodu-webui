# frozen_string_literal: true

# Current — request-scoped globals (ActiveSupport::CurrentAttributes). Rails
# resets these automatically at the end of every request/job, so there's no
# thread-leak between requests the way a bare Thread.current would risk.
#
# `org` is set once per request by ApplicationController (from the URL's
# :org_id segment). WebTime reads Current.org.timezone so server-rendered
# timestamps land in the org's configured zone without threading the org
# through every view/component call.
# `user` is the local ::User mirroring the signed-in Clowk subject, set by the
# Authentication concern. Everything that asks "may this person…" resolves from
# it, so it must never be assigned from anything but a verified token.
class Current < ActiveSupport::CurrentAttributes
  attribute :org
  attribute :user
  # The acting user's role in the resolved org, or nil when there is no active
  # membership — which Permissions treats as a denial, never as a default.
  attribute :role
  # The membership itself, so authorized_servers can read its grants without a
  # second query per request.
  attribute :membership

  attribute :resolved_license

  # What this INSTALLATION is licensed as, reachable from anywhere.
  #
  # `entitlements` answers "how many orgs may exist"; this answers "which
  # product is this". Both matter, and only the first had a home — the second
  # was resolved ad hoc wherever somebody needed it, which meant a model or a
  # job could not ask at all without reaching for the class directly.
  #
  # Memoised per request, because resolving verifies an RSA signature and reads
  # the database, and this is now cheap enough to call in a view. Rails clears
  # Current at the end of every request and every job, so a licence activated
  # mid-session is picked up on the next one rather than cached until deploy.
  # Held in a real attribute, not in `attributes[...]`.
  #
  # CurrentAttributes#attributes returns a COPY, so `attributes[:license] ||= …`
  # writes to a hash that is thrown away — the memoisation looked right and
  # resolved the licence on every single call, RSA verification and database
  # read included. Only a declared attribute has a writer that reaches the
  # store.
  def self.license
    self.resolved_license ||= LicenseToken.current
  end

  # The three tiers, as questions. Deliberately exhaustive and mutually
  # exclusive: code that asks "am I free" and code that asks "am I unlimited"
  # should never both be true, and a fourth tier added later has to make
  # somebody choose where it belongs rather than falling silently into `free`.
  def self.free? = license.tier == "free"

  def self.enterprise? = license.tier == "enterprise"

  def self.unlimited? = license.tier == "unlimited"

  # True for anything somebody paid for — the common question, so it does not
  # get written as `enterprise? || unlimited?` in five places and forgotten in
  # the sixth when a tier is added.
  def self.licensed? = !free?
end
