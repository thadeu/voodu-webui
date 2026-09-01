# frozen_string_literal: true

require "test_helper"

# The scheme on the Clowk subdomain URL, which nobody types and everybody needs.
#
# The gem is inconsistent about it: Clowk::Subdomain prepends https:// when the
# value has no scheme, so the sign-in REDIRECT is built correctly — but
# Clowk::Jwks.default_url reads `config.subdomain_url` raw and skips that, so
# the JWKS fetch during token verification gets "host/.well-known/jwks.json"
# and Net::HTTP raises `ArgumentError (not an HTTP URI)`.
#
# The consequence is as bad as it gets for a configuration slip: the app boots
# fine, the redirect out to Clowk works, the operator signs in there — and the
# OAuth callback 500s on the way back. Nothing before that point complains, and
# the failure lands on the one request there is no way to retry past.
class AuthSettingsUrlTest < ActiveSupport::TestCase
  test "a bare host is given the scheme the gem will not add" do
    assert_equal "https://lima--creek.clowk.dev",
      AuthSettings.normalize_url("lima--creek.clowk.dev")
  end

  test "a URL that already has one is left alone" do
    assert_equal "https://acme.clowk.dev", AuthSettings.normalize_url("https://acme.clowk.dev")
    assert_equal "http://localhost:4000", AuthSettings.normalize_url("http://localhost:4000")
  end

  test "surrounding whitespace does not become part of the host" do
    assert_equal "https://acme.clowk.dev", AuthSettings.normalize_url("  acme.clowk.dev\n")
  end

  # nil, not "https://" — an empty setting means "not configured", and the gem
  # falls back to resolving the instance from the publishable key. A bare
  # scheme would be a URL that resolves to nothing and hides that fallback.
  test "blank stays nothing at all" do
    assert_nil AuthSettings.normalize_url(nil)
    assert_nil AuthSettings.normalize_url("")
    assert_nil AuthSettings.normalize_url("   ")
  end

  # Both sources reach the gem through the same door, so a value pasted into
  # the SSO form cannot be a trap that the same value in the environment is not.
  test "the environment is normalised on the way in" do
    ENV["CLOWK_SUBDOMAIN_URL"] = "lima--creek.clowk.dev"
    ENV["CLOWK_ENABLED"] = "1"

    assert_equal "https://lima--creek.clowk.dev", AuthSettings.from_env.subdomain_url
  ensure
    ENV.delete("CLOWK_SUBDOMAIN_URL")
    ENV.delete("CLOWK_ENABLED")
  end

  # The stored path is closed at the other end: the model refuses a bare host
  # outright, so the form cannot save the trap in the first place. Pinned here
  # beside the env case so it is visible that the two doors are shut by
  # different means — validation there, normalisation here — and that removing
  # either one leaves a door open.
  test "the SSO form refuses a bare host instead of storing one" do
    config = Ops::SsoConfig.new(
      provider: :clowk, publishable_key: "pk_test_x", subdomain_url: "acme.clowk.dev"
    )

    assert_not config.valid?
    assert_match(/https/, config.errors[:subdomain_url].to_sentence)
  end

  test "and accepts the same host with a scheme" do
    config = Ops::SsoConfig.new(
      provider: :clowk, publishable_key: "pk_test_x", subdomain_url: "https://acme.clowk.dev"
    )

    assert_empty config.errors[:subdomain_url].tap { config.valid? }
  end

  # The end of the chain: whatever the gem is handed must be something
  # Net::HTTP will accept, which is the check that actually failed in the wild.
  test "what reaches the gem builds a JWKS URL Net::HTTP accepts" do
    url = "#{AuthSettings.normalize_url("lima--creek.clowk.dev")}/.well-known/jwks.json"

    assert_nothing_raised { Net::HTTP::Get.new(URI(url)) }
  end
end
