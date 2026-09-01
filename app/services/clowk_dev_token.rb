# frozen_string_literal: true

require "jwt"

# ClowkDevToken — mints a token the real verifier accepts, without a Clowk
# instance, without the network, without any clowk.in configuration.
#
# Authentication is mandatory: there is no unrestricted mode to fall back on.
# That is the right posture for production and an unworkable one for `bin/dev`
# and the test suite, which would otherwise need a live broker to render a
# single page. This closes that gap, and nothing else.
#
# Clowk::JwtVerifier checks signature, issuer and expiry on the HS256 path — so
# a token signed here is INDISTINGUISHABLE from one the broker issued. That is
# the whole point, and it is also why this must never exist in production.
# Two locks, deliberately independent:
#
#   1. The route that uses it (Dev::SessionsController) is defined only under
#      `Rails.env.development?` in config/routes.rb, so it is not in the
#      production route table at all.
#   2. The raise below, in case someone widens that condition.
class ClowkDevToken
  # Signs with whatever Clowk is configured to verify with. Outside production
  # that is a key derived from secret_key_base (config/initializers/clowk.rb),
  # unless the operator supplied a real CLOWK_SECRET_KEY. In production it is
  # nil and this class raises before reaching the encode either way.
  DEFAULT_TTL = 12.hours

  def self.mint(sub:, email:, name: nil, email_verified: true, ttl: DEFAULT_TTL)
    raise "ClowkDevToken is a development and test affordance only" if Rails.env.production?

    payload = {
      sub: sub,
      email: email,
      email_verified: email_verified,
      name: name,
      provider: "dev",
      session_id: "dev-#{sub}",
      iss: Clowk.config.issuer,
      exp: ttl.from_now.to_i
    }

    # The same source the verifier reads, so what this mints is what
    # Clowk::JwtVerifier will accept. Reading the global while verification had
    # moved to the scoped credentials would make the dev door mint tokens the
    # app then rejects.
    JWT.encode(payload, Clowk.credentials.secret_key, "HS256")
  end
end
