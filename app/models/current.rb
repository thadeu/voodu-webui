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
end
