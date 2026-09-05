# frozen_string_literal: true

# Integration::Github::AppJwt — the App's own credential.
#
# GitHub Apps authenticate in two steps: sign a short JWT with the App's
# private key to prove you ARE the App, then exchange it for an installation
# token scoped to one customer's repositories. This is the first step; the
# second lives in Integration::Github::Client.
#
# SIGNED WITH OpenSSL RATHER THAN A JWT GEM, and that is a considered choice
# rather than thrift. The `jwt` gem is present only transitively (clowk pulls
# it), so depending on it here would break the day clowk drops it. And the
# famous JWT vulnerabilities — `alg: none`, algorithm confusion, key confusion
# — are all failures of VERIFICATION. Signing a fixed-shape token with a known
# key is base64 and one OpenSSL call, with no algorithm to be talked out of.
#
# We never verify a JWT here. GitHub does that, with our public key.
class Integration::Github::AppJwt
  # TTL is short because the token is used immediately, to swap for another.
  #
  # GitHub refuses anything over 10 minutes, and clocks drift: a machine a
  # minute fast against GitHub would mint tokens already expired. Nine minutes
  # leaves room for that without approaching the ceiling.
  TTL = 9.minutes

  # BACKDATE absorbs the same drift in the other direction. A machine a few
  # seconds ahead issues a token GitHub reads as "from the future" and rejects
  # outright — a failure that looks like a bad key and is not.
  BACKDATE = 30.seconds

  class MissingCredentials < StandardError; end

  def self.generate(settings = GithubSettings.current)
    new(settings).generate
  end

  def initialize(settings)
    @settings = settings
  end

  def generate
    unless @settings.configured?
      raise MissingCredentials, "no GitHub App is configured on this installation"
    end

    now = Time.now.to_i

    payload = {
      iat: now - BACKDATE.to_i,
      exp: now + TTL.to_i,
      iss: @settings.app_id
    }

    signing_input = "#{encode(header)}.#{encode(payload)}"

    "#{signing_input}.#{base64url(private_key.sign(OpenSSL::Digest.new("SHA256"), signing_input))}"
  end

  private

  def header = {alg: "RS256", typ: "JWT"}

  def encode(hash) = base64url(JSON.generate(hash))

  # base64url, not strict_encode64: JWT uses the URL alphabet and drops the
  # padding, and a `+` or `=` in the token is rejected by GitHub as malformed.
  def base64url(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

  def private_key
    OpenSSL::PKey::RSA.new(@settings.private_key)
  rescue OpenSSL::PKey::RSAError => e
    # The most common cause is a truncated or escaped paste, and the operator
    # needs to hear that rather than "nested asn1 error".
    raise MissingCredentials,
      "the GitHub App private key could not be read (#{e.message}); it should be the full .pem contents"
  end
end
