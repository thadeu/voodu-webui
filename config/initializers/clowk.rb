# frozen_string_literal: true

# Operator sign-in via Clowk.in — MANDATORY.
#
# The WebUI reaches every controller it manages, holding a PAT that can deploy,
# exec and read logs on each one. There is no unrestricted mode: every request
# carries an identity, and every identity reaches only what a membership grants
# it. A dashboard that answers to whoever finds the port is not a posture we
# support, because a mistake there is not a leaked chart — it is somebody
# else's infrastructure.
#
# Production needs two env vars:
#
#   CLOWK_PUBLISHABLE_KEY  REQUIRED. Identifies the Clowk instance: the hosted
#                          sign-in URL, the JWKS endpoint and the token
#                          audience are all derived from it.
#   CLOWK_SECRET_KEY       OPTIONAL. Clowk signs with RS256 and we verify
#                          against the public JWKS, so sign-in works without
#                          it. It buys two things: tokens minted before Clowk's
#                          RS256 migration (HS256, which raises without the
#                          secret), and the management-API session lookup
#                          behind `enforce_active_session`, which we leave off.
#
# Development and test need neither: with no secret configured they fall back to
# the local literal below, which lets `bin/dev` and the suite mint HS256 tokens
# the real verifier accepts (see ClowkDevToken for why that is safe only outside
# production, and for the two locks that keep it there).

clowk_publishable_key = ENV["CLOWK_PUBLISHABLE_KEY"].to_s.strip

if Rails.env.production? && clowk_publishable_key.empty?
  raise "CLOWK_PUBLISHABLE_KEY is required — the Clowk instance, its JWKS endpoint " \
        "and the token audience are all derived from it, and sign-in is mandatory."
end

Clowk.configure do |config|
  # Public. Doubles as the expected `aud` on incoming tokens — under RS256 every
  # consumer trusts the same public key, so the audience check is what keeps
  # another app's token out of this one.
  config.publishable_key = clowk_publishable_key.presence

  # Server-to-server calls to the Clowk API, and the legacy HS256 path.
  # Verifying a current token does not need it: that runs against the published
  # key set. The literal fallback is TEST ONLY — the suite signs in through
  # ClowkDevToken, which mints HS256, and the verifier needs the same secret to
  # check it. Without one, every integration test dies in JWT::DecodeError at
  # sign_in_as and it reads as 700 unrelated failures. CI has no .env, so the
  # fallback is what keeps the suite honest there.
  config.secret_key = ENV.fetch("CLOWK_SECRET_KEY", nil).presence || "clowk-test-secret-not-for-production"

  # The instance's auth domain. Set it explicitly and the gem stops resolving it
  # through api.clowk.dev — one fewer network dependency on the path that
  # authenticates every request, and on the JWKS fetch behind it. Left nil, the
  # gem derives it from the publishable key on first use.
  config.subdomain_url = ENV.fetch("CLOWK_SUBDOMAIN_URL", nil).presence

  # Names the installed helpers current_clowk_user / clowk_user_signed_in? /
  # clowk_user_sign_out!. Deliberately not :user — `current_user` must keep
  # returning a local ::User, not the gem's claims object.
  config.prefix_by = :clowk_user

  # Kept in sync with config/routes.rb by hand: the gem builds sign-in and
  # sign-out paths from mount_path, and the redirect_uri from callback_path.
  config.mount_path = ""
  config.callback_path = "/oauth/callback"

  config.after_sign_in_path = "/"
  config.after_sign_out_path = "/"

  # Trust the JWT until it expires. The alternative — a broker round-trip per
  # authentication — would land on the critical path of every page AND of the
  # metrics/logs turbo frames that re-poll every 30s. Revocation therefore
  # takes effect when the token expires; Authentication::SESSION_HARD_CEILING
  # bounds how long that can be.
  config.enforce_active_session = false

  config.http_logger = Rails.logger
end
