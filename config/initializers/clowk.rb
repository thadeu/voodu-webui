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

# Resolved once, here, so every reader agrees — the concern that guards requests,
# the components that decide what to draw, and the tests that exercise both.
#
# The `true`/`false` test is NOT a nil check, and that distinction is the whole
# correctness of the default. `config.x.anything_unset` returns an empty
# ActiveSupport::OrderedOptions, which is neither nil NOR falsey — so `.nil?`
# here would never fire, ENV would never be read, and every deployment would
# come up with sign-in ON. Exactly backwards, and invisible to the suite,
# because config/environments/test.rb assigns a real boolean.
#
# Anything that is not already a real boolean means "nobody has decided yet".
# An environment file may decide (it loads BEFORE initializers; the test env
# pins true so the existing suite keeps exercising the multi-tenant path);
# otherwise ENV decides, and its default is off.
unless [true, false].include?(Rails.application.config.x.clowk_enabled)
  flag = ENV["CLOWK_ENABLED"].to_s.strip.downcase

  Rails.application.config.x.clowk_enabled =
    if flag.empty?
      # Unset does NOT mean off when Clowk is already configured. An install
      # running with a publishable key today is an install where somebody chose
      # sign-in; shipping a release that reads "unset" as "anonymous" would turn
      # their dashboard into one that answers to whoever reaches the port, on a
      # restart, silently. Upgrades must not remove authentication.
      #
      # Fresh installs have no key, so they still land on anonymous — the
      # self-hosted default is intact. To go anonymous while keeping a key
      # around, say so: CLOWK_ENABLED=0.
      ENV["CLOWK_PUBLISHABLE_KEY"].to_s.strip.present?
    else
      %w[1 true yes on].include?(flag)
    end
end

# Said once, at boot, so it lands in `docker logs` where an operator setting the
# container up will actually see it — the UI banner only fires once a request
# arrives from outside, and by then the exposure already happened.
unless Rails.application.config.x.clowk_enabled
  Rails.application.config.after_initialize do
    Rails.logger.warn(
      "[auth] CLOWK_ENABLED is off — no sign-in. Every request runs as one local " \
      "operator with owner rights, which includes reading each server's access " \
      "token. Keep this behind a VPN or an access proxy; do not publish the port."
    )
  end
end

clowk_publishable_key = ENV["CLOWK_PUBLISHABLE_KEY"].to_s.strip

# Only when sign-in is actually the door. Raising here with the flag off would
# make the self-hosted `docker run` — the default shape — die at boot.
if Rails.application.config.x.clowk_enabled && Rails.env.production? && clowk_publishable_key.empty?
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
