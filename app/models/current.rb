# frozen_string_literal: true

# Current — request-scoped globals (ActiveSupport::CurrentAttributes). Rails
# resets these automatically at the end of every request/job, so there's no
# thread-leak between requests the way a bare Thread.current would risk.
#
# `org` is set once per request by ApplicationController (from the URL's
# :org_id segment). WebTime reads Current.org.timezone so server-rendered
# timestamps land in the org's configured zone without threading the org
# through every view/component call.
class Current < ActiveSupport::CurrentAttributes
  attribute :org
end
