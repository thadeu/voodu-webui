# frozen_string_literal: true

# Authentication — every request carries an identity.
#
# WHERE that identity comes from is the one deployment switch (see
# config/initializers/clowk.rb):
#
#   CLOWK_ENABLED=1   The token is verified by the gem, and the verified subject
#                     is mirrored onto a local ::User. Sign-in is the door.
#   otherwise         Anonymous. The door is the PERIMETER — Twingate, a VPN,
#                     Cloudflare Access — and the request runs as the single
#                     User.local_operator row.
#
# Anonymous is not "no identity". It resolves a real User with a real owner
# membership, so `Current.user` is populated either way and every authorization
# check downstream keeps working unchanged. Nothing past this concern branches
# on how sign-in happened, which is deliberate: one authorization path is the
# whole reason this is safe to offer.
#
# Two surfaces stay outside, on purpose, and must stay that way:
#
#   - `/up` is rails/health#show, not an ApplicationController subclass. The
#     image HEALTHCHECK curls it every 30s and has no session to offer.
#   - `/internal/poller/*` are ActionController::API. Redirecting the Go poller
#     to a sign-in page would silently stop the warehouse refilling. They carry
#     their own auth (POLLER_TOKEN plus a private-IP guard).
module Authentication
  extend ActiveSupport::Concern

  # A local cap the broker plays no part in.
  #
  # Clowk::Authenticable resolves `stored_user_payload || verified_request_payload`
  # — so once the Rails session exists, the JWT's `exp` is never re-checked and
  # the session lives as long as the session cookie. Without a ceiling here, a
  # token that expired hours ago keeps working in an open tab.
  SESSION_HARD_CEILING = 12.hours

  included do
    include Clowk::Authenticable

    before_action :reject_stray_token
    before_action :require_authentication!
    before_action :resolve_current_user
  end

  class_methods do
    # Fully public: no identity resolved, no redirect. Nothing uses it yet — it
    # exists so the next public endpoint is an explicit opt-out rather than a
    # reason to make the guard itself conditional.
    def allow_unauthenticated(**opts)
      skip_before_action :reject_stray_token, **opts
      skip_before_action :require_authentication!, **opts
      skip_before_action :resolve_current_user, **opts
    end
  end

  # Read from config rather than ENV so one value answers for the whole process
  # and a test can flip it without reaching into the environment.
  def clowk_enabled?
    Rails.application.config.x.clowk_enabled
  end

  private

  # Clowk::Middleware::TokenExtractor can read a token from params, and
  # Authenticable persists whatever verifies — so a valid token in a query
  # string would establish a session on ANY path, bypassing the `state` check
  # that makes the callback safe, and would stay replayable anywhere that URL
  # was logged. The gem passes `token_param: nil` today; this is the lock that
  # does not depend on the gem continuing to.
  def reject_stray_token
    return if params[Clowk.config.token_param].blank?
    return if request.path == Clowk.config.callback_path

    Rails.logger.warn("[auth] rejected stray token param on #{request.path}")
    head :bad_request
  end

  # `clowk_sign_in_path` — the gem derives it from Clowk.config.mount_path, so
  # the door is configured in the initializer and this follows it.
  #
  # The redirect is spelled out here rather than delegated to
  # `authenticate_clowk_user!` on purpose: overriding the gem's
  # clowk_handle_unauthenticated hook does not work from this concern.
  # Clowk::Authenticable is included from INSIDE it, which puts the gem CLOSER
  # to the controller in the ancestor chain than we are — an override here
  # loses silently, which is worse than not having one.
  # Anonymous mode has no door to send anyone to, and no session to age out —
  # resolve_current_user supplies the identity instead.
  def require_authentication!
    return unless clowk_enabled?
    return force_reauthentication if session_beyond_ceiling?
    return if clowk_user_signed_in?

    redirect_to sign_in_destination
  end

  # Mirror the verified subject onto a local row and publish it. A cache miss
  # here is one indexed read; provisioning only runs when the row is new or the
  # mirrored profile has gone stale.
  def resolve_current_user
    unless clowk_enabled?
      Current.user = User.local_operator
      return
    end

    return unless clowk_user_signed_in?

    Current.user = User.provision_from_clowk!(current_clowk_user.to_h)
  end

  def current_user
    Current.user
  end

  # Clear BOTH the session claims and the token cookie. Leaving the cookie
  # would let the next request re-establish the session from the still-valid
  # JWT — the signature is fine, it is the age we are objecting to — and loop
  # the operator straight back in.
  def force_reauthentication
    clowk_user_sign_out!

    redirect_to sign_in_destination, alert: "Your session has ended. Please sign in again."
  end

  # The engine's /sign_in builds a redirect to the hosted Clowk instance, which
  # needs a publishable key to resolve. In development there usually isn't one
  # — the local flow mints its own token — and without this the first page a
  # developer meets is a 500. Production always has the key (the initializer
  # refuses to boot otherwise), so this branch never fires there.
  def sign_in_destination
    if Rails.env.development? && Clowk.config.publishable_key.blank?
      return dev_sign_in_path(return_to: request.fullpath)
    end

    clowk_sign_in_path(return_to: request.fullpath)
  end

  def session_beyond_ceiling?
    started = signed_in_at

    started.positive? && Time.current.to_i - started > SESSION_HARD_CEILING.to_i
  end

  # The gem writes `signed_in_at` at sign-in and never reads it again — this is
  # the only consumer.
  def signed_in_at
    raw = session[Clowk.config.session_key]
    return 0 unless raw.respond_to?(:to_h)

    (raw.to_h["signed_in_at"] || raw.to_h[:signed_in_at]).to_i
  end
end
