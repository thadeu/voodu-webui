# frozen_string_literal: true

# Optional operator sign-in via Clowk.in.
#
# The WebUI has no users table and no login of its own — every page is
# reachable by anyone who reaches the port. That is fine behind a VPN or the
# Caddy Basic Auth front door (docker-compose.auth.yml), and not fine on the
# open internet. Setting CLOWK_AUTH_ENABLED=1 puts a real identity in front
# of the whole dashboard: the gem verifies the JWT Clowk issues and keeps the
# claims in the Rails session. Nothing is persisted locally.
#
# Env vars, all read here and nowhere else:
#
#   CLOWK_AUTH_ENABLED=1     the switch
#   CLOWK_PUBLISHABLE_KEY    REQUIRED. Identifies the Clowk instance. Both the
#                            hosted sign-in URL and the JWKS endpoint are
#                            derived from it, and it is the `aud` the verifier
#                            enforces.
#   CLOWK_SECRET_KEY         OPTIONAL — see below.
#
# Why the secret is optional: Clowk signs with RS256 now, and
# Clowk::JwtVerifier picks its path from the token's own `alg` header. RS256
# goes to Jwks.key_for, which resolves
# `Subdomain.resolve_url!(publishable_key) + /.well-known/jwks.json` and
# verifies against the PUBLIC key (cached 600s, refetched on an unknown kid).
# The secret is never touched. It buys exactly two things:
#
#   1. HS256 tokens minted before Clowk's RS256 migration. Verifying one
#      without the secret raises Clowk::ConfigurationError, and Authenticable
#      only rescues InvalidTokenError — so that surfaces as a 500, not a
#      redirect to sign-in. A fresh instance never issues them.
#   2. The management-API session lookup behind `enforce_active_session`,
#      which we leave off. Without the secret it degrades quietly
#      (`return unless Clowk.config.secret_key.present?`), it does not raise.
#
# Unset (or anything other than "1") leaves the app exactly as it was: no
# mounted routes, no before_action, no network calls to Clowk.

clowk_flag_on = ENV["CLOWK_AUTH_ENABLED"] == "1"
clowk_publishable_key = ENV["CLOWK_PUBLISHABLE_KEY"].to_s.strip

# Fail at boot, not at the first request. Booting green with the switch on and
# no publishable key would serve the dashboard wide open to an operator who
# believes it is behind a login — the one outcome worth refusing to start over.
if clowk_flag_on && clowk_publishable_key.empty?
  raise "CLOWK_AUTH_ENABLED=1 but CLOWK_PUBLISHABLE_KEY is missing — the Clowk instance, " \
        "its JWKS endpoint and the token audience are all derived from it. " \
        "Set it, or unset CLOWK_AUTH_ENABLED to run without sign-in."
end

# Resolved once, at boot, and read everywhere else through ClowkAuth.enabled?
# — config/routes.rb decides whether to mount the engine, ClowkGuard decides
# whether to demand a session. One computation, no drift between the two.
Rails.application.config.x.clowk_auth_enabled = clowk_flag_on && clowk_publishable_key.present?

# Configured unconditionally, including when the switch is off, because
# Clowk::Authenticable reads `prefix_by` at include time to name the methods it
# installs. Leaving it to the gem's default when disabled would rename
# current_clowk_user out from under ClowkGuard depending on the environment.
# With no keys and no guard, none of this is ever exercised.
Clowk.configure do |config|
  config.publishable_key = ENV["CLOWK_PUBLISHABLE_KEY"]

  # nil unless the operator supplied one. Only the legacy HS256 path and the
  # session-status lookup read it; RS256 verification does not.
  config.secret_key = ENV["CLOWK_SECRET_KEY"].presence

  # Names the installed helpers current_clowk_user / clowk_user_signed_in? /
  # clowk_user_sign_out!. Deliberately not :user — `current_user` reads like a
  # local record, and this project has none.
  config.prefix_by = :clowk_user

  config.mount_path = "/clowk"
  config.callback_path = "/clowk/oauth/callback"

  # Root, which bounces to the first server's overview (or /servers/new).
  config.after_sign_in_path = "/"
  config.after_sign_out_path = "/"

  # Trust the JWT until it expires. The alternative — a broker round-trip per
  # authentication — would land on the critical path of every page AND of the
  # metrics/logs turbo frames that re-poll every 30s. Revocation therefore
  # takes effect when the token expires, which is the right trade for a
  # handful of operators. Flip to true (with session_status_ttl) if this ever
  # holds more than a small trusted group.
  config.enforce_active_session = false

  config.http_logger = Rails.logger
end
