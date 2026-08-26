# frozen_string_literal: true

# ClowkGuard — demands a Clowk session on every page, when switched on.
#
# Included by ApplicationController, so it covers the whole navigable
# surface: the server-scoped pages, /servers, /styleguide, the drawer and
# turbo-frame endpoints. Two things sit outside it on purpose and must stay
# that way:
#
#   - /up is rails/health#show, not a subclass of ApplicationController. The
#     image HEALTHCHECK curls it every 30s and has no session to offer.
#   - /internal/poller/* are ActionController::API. Redirecting the Go poller
#     to a sign-in page would silently stop the warehouse from refilling.
#     They carry their own auth (POLLER_TOKEN + a private-IP guard).
#
# Whether auth is live is decided at boot (see ClowkAuth); with the switch off
# this concern costs one predicate call per request and nothing else. The
# check is per-request rather than a conditional `include` so the behaviour
# follows the flag instead of whatever the class happened to see at load time.
module ClowkGuard
  extend ActiveSupport::Concern

  included do
    # Installs current_clowk_user / clowk_user_signed_in? / authenticate_clowk_user!
    # / clowk_user_sign_out!, named from Clowk.config.prefix_by.
    include Clowk::Authenticable

    before_action :require_clowk_auth!
  end

  class_methods do
    # Opt one controller (or a few actions) out of the session requirement.
    # Nothing uses it yet — it exists so the next public endpoint doesn't get
    # bolted on by making the guard itself conditional.
    def allow_unauthenticated(**opts)
      skip_before_action :require_clowk_auth!, **opts
    end
  end

  private

  # Unauthenticated visitors get the gem's redirect to /clowk/sign_in with
  # return_to set to where they were headed, so signing in lands them on the
  # page they asked for instead of the dashboard root.
  def require_clowk_auth!
    return unless ClowkAuth.enabled?

    authenticate_clowk_user!
  end
end
