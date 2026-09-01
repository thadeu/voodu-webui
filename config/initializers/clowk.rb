# frozen_string_literal: true

# Operator sign-in via Clowk.in — OPTIONAL, and off by default.
#
# Two deployment shapes come out of this one image, and the flag is which:
#
#   CLOWK_ENABLED unset/0/false  Anonymous. The app resolves one local operator
#                                and asks for no credentials. The PERIMETER
#                                authenticates — Twingate, Cloudflare Access, a
#                                VPN — and whoever reaches the port has already
#                                proved who they are to it. This is the
#                                self-hosted default: `docker run`, nothing else.
#
#   CLOWK_ENABLED=1              Clowk. Identity per person, orgs, invitations,
#                                per-server grants. This is the hosted SaaS.
#
# Anonymous mode is NOT a bypass: it provisions a real User with a real owner
# membership, so authorization keeps running through the single path every other
# request uses (see Authentication and User.local_operator). What it does mean is
# that whoever reaches the port is an owner, and an owner can reveal a PAT — and
# a PAT is the whole controller, not a chart. Running anonymous with the port
# open to the internet hands over the infrastructure; PerimeterWarning says so
# in the UI, loudly, when it sees a request arrive from a public address.
#
# With the flag on, production needs:
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

# NOTHING RESOLVES THE FLAG HERE ANY MORE, and that removal is the fix.
#
# This used to read ENV at boot and write the answer into
# config.x.clowk_enabled, which Authentication#clowk_enabled? then returned
# without consulting anything else. The trouble was not the caching, it was that
# SILENCE WAS RECORDED AS AN ANSWER: with neither variable set — which is every
# self-hosted box — it pinned `false`, so AuthSettings.from_database was
# unreachable and the SSO screen's whole promise was dead code. Turning sign-in
# on stored a row nothing ever read: the screen reported success, the badge kept
# saying `none`, and every request went on running as the anonymous operator
# with the dashboard open to whoever reached the port. Being told the door is
# shut while it stands open is worse than knowing it is open.
#
# It also meant the environment's rule was written twice — here and in
# AuthSettings.from_env — and only one of the two knew about the stored row.
# One copy survives, in AuthSettings, which already owns the precedence:
#
#   1. a real boolean in config.x.clowk_enabled — an environment file or a test
#   2. the ENVIRONMENT — CLOWK_ENABLED / CLOWK_PUBLISHABLE_KEY
#   3. the DATABASE — the row the SSO screen writes
#
# config.x.clowk_enabled is therefore left alone: config/environments/test.rb
# pins `true` so the suite keeps exercising the multi-tenant path, and nothing
# in development or production writes it at all. Undecided stays undecided, and
# sign-in turns on and off from the screen on the next request, no redeploy.
clowk_publishable_key = ENV["CLOWK_PUBLISHABLE_KEY"].to_s.strip

# Said once, at boot, so it lands in `docker logs` where an operator setting the
# container up will actually see it — the UI banner only fires once a request
# arrives from outside, and by then the exposure already happened.
#
# Asked of AuthSettings rather than of the pin, and inside `after_initialize`
# rather than here, because the stored row is now a real source: an installation
# that turned sign-in on from the screen is NOT anonymous, and warning that it
# is would teach operators to ignore the one line that matters. Deferred because
# AuthSettings is autoloaded, and reading it while initializers run is what
# Rails refuses to allow. from_database never raises — a missing table during
# `db:prepare` or an assets build resolves to "off", which is the safe way to be
# wrong about a warning.
Rails.application.config.after_initialize do
  next if AuthSettings.effective.enabled?

  Rails.logger.warn(
    "[auth] sign-in is off — no identity. Every request runs as one local " \
    "operator with owner rights, which includes reading each server's access " \
    "token. Keep this behind a VPN or an access proxy; do not publish the port."
  )
end

# Only when the ENVIRONMENT is what demands sign-in, which is the only case this
# can speak to. Asked of ENV rather than of config.x.clowk_enabled: a stored
# configuration carries its own key and is validated when it is saved, so the
# operator who turns sign-in on from the screen must not be refused a boot for a
# variable they were never asked to set.
#
# Raising with sign-in off would make the self-hosted `docker run` — the default
# shape — die at boot, so the flag has to be read strictly.
if %w[1 true yes on].include?(ENV["CLOWK_ENABLED"].to_s.strip.downcase) &&
    Rails.env.production? && clowk_publishable_key.empty?
  raise "CLOWK_PUBLISHABLE_KEY is required when CLOWK_ENABLED=1 — the Clowk instance, " \
        "its JWKS endpoint and the token audience are all derived from it."
end

Clowk.configure do |config|
  # Public. Doubles as the expected `aud` on incoming tokens — under RS256 every
  # consumer trusts the same public key, so the audience check is what keeps
  # another app's token out of this one.
  config.publishable_key = clowk_publishable_key.presence

  # Server-to-server calls to the Clowk API, and the legacy HS256 path.
  #
  # NEVER INVENTED. Whatever sits here is, on its own, enough to mint a token
  # for any subject and any address: Clowk::JwtVerifier routes a token to HS256
  # whenever its `alg` is not RS256, and that path does not check the audience.
  # A default here would therefore not be a weak fallback, it would be a
  # credential — and one published in this repository, on an installation
  # running the setup .env.example calls normal (RS256, no CLOWK_SECRET_KEY,
  # because verifying against the public JWKS needs no secret at all).
  #
  # nil is the correct value when the operator supplied nothing: the verifier
  # raises "missing Clowk secret_key" and the legacy path is shut.
  #
  # The consequence to know about, because it is not obvious: ClowkDevToken
  # signs HS256, so `/dev/sign_in` needs a secret to exist. It does not get one
  # from here. Set CLOWK_SECRET_KEY in .env to use it; the suite configures its
  # own per-run secret in test_helper.rb, which is its harness rather than this
  # application's configuration.
  config.secret_key = ENV.fetch("CLOWK_SECRET_KEY", nil)

  # The instance's auth domain. Set it explicitly and the gem stops resolving it
  # through api.clowk.dev — one fewer network dependency on the path that
  # authenticates every request, and on the JWKS fetch behind it. Left nil, the
  # gem derives it from the publishable key on first use.
  # Normalised, not passed through: a bare host here 500s the OAuth callback.
  # AuthSettings.normalize_url carries the full reasoning and does this for the
  # env and stored credentials both — spelled out again rather than called
  # because app/ is not autoloadable this early, and the four lines are cheaper
  # than moving the class or deferring the whole configure block.
  subdomain = ENV.fetch("CLOWK_SUBDOMAIN_URL", nil).to_s.strip
  subdomain = "https://#{subdomain}" if subdomain.present? && !subdomain.start_with?("http://", "https://")

  config.subdomain_url = subdomain.presence

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
