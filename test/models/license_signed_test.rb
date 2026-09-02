# frozen_string_literal: true

require "test_helper"

# Minting the other half of the licence story.
#
# LicenseToken is the reader and never raises — a licence that can throw can
# take a customer's monitoring down. Signed is the writer and raises for
# everything, because the failure it is guarding against is the opposite one: a
# token that verifies and grants no more than having none. The customer paid,
# the screen says it activated, and nobody finds out until they ask why nothing
# changed. So every case below asserts a refusal BEFORE a signature exists.
#
# The pair also has to hold end to end: what this signs, LicenseToken.resolve
# must read back as the same product.
class LicenseSignedTest < ActiveSupport::TestCase
  FIXTURES = Rails.root.join("test/fixtures/files")
  KEY = OpenSSL::PKey::RSA.new(FIXTURES.join("license_test_private_key.pem").read)
  PUBLIC = OpenSSL::PKey::RSA.new(FIXTURES.join("license_test_public_key.pem").read)

  def signed(**overrides)
    LicenseToken::Signed.new(subject: "acme-corp", days: 365, key: KEY, **overrides)
  end

  def read_back(token)
    LicenseToken.resolve(token, key: PUBLIC)
  end

  # ── What it signs ──────────────────────────────────────────────────────

  test "an installation licence reads back as the tier it was sold as" do
    licence = read_back(signed(tier: "enterprise").generate!)

    assert_equal :valid, licence.status
    assert_equal "enterprise", licence.tier
    assert_equal "acme-corp", licence.customer
  end

  # Unknown tiers fall back to enterprise on the READ side, so a licence with no
  # tier claim is still a licence. Asserting it here keeps that contract visible
  # from the minting end, where it would otherwise look like an omission.
  test "a licence with no tier claim is still enterprise when read" do
    token = signed.generate!

    assert_not_includes JWT.decode(token, PUBLIC, true, algorithm: "RS256").first.keys, "tier"
    assert_equal "enterprise", read_back(token).tier
  end

  test "entitlement overrides travel in ent, not at the top level" do
    licence = read_back(signed(tier: "enterprise", entitlements: {"retention_days" => 180}).generate!)

    assert_equal({retention_days: 180}, licence.granted)
  end

  test "expiry is days from now" do
    token = signed(days: 30).generate!

    assert_in_delta 30.days.from_now.to_i, read_back(token).expires_at.to_i, 5
  end

  # ── Plans carry their tier by construction ─────────────────────────────
  #
  # Entitlements#plan reads the account's plan only when the tier is unlimited
  # and ignores it otherwise, so a plan licence signed with any other tier is a
  # token that verifies and does nothing. The caller cannot get that wrong here
  # because the caller does not supply it.

  test "a plan licence carries tier unlimited without being asked" do
    licence = read_back(signed(subject: "Pz9IUrm2", plan: "pro").generate!)

    assert_equal "unlimited", licence.tier
    assert_equal "pro", licence.plan
    assert_equal "Pz9IUrm2", licence.subject_account
  end

  test "a plan licence refuses a tier that would make it inert" do
    error = assert_raises(ArgumentError) { signed(plan: "pro", tier: "enterprise").generate! }

    assert_match(/hosted-only/, error.message)
  end

  test "an explicit unlimited alongside a plan is accepted" do
    assert_equal "unlimited", read_back(signed(plan: "pro", tier: "unlimited").generate!).tier
  end

  # ── What it refuses ────────────────────────────────────────────────────

  test "a blank subject is refused" do
    assert_raises(ArgumentError) { signed(subject: "  ").generate! }
  end

  test "days must be positive" do
    assert_raises(ArgumentError) { signed(days: 0).generate! }
    assert_raises(ArgumentError) { signed(days: -1).generate! }
  end

  test "an unknown tier is refused rather than signed" do
    error = assert_raises(ArgumentError) { signed(tier: "banana").generate! }

    assert_match(/enterprise, unlimited/, error.message)
  end

  test "an unknown plan is refused rather than signed" do
    assert_raises(ArgumentError) { signed(plan: "platinum").generate! }
  end

  # A typo that silently signed an entitlement nothing reads would look granted
  # and behave free, and the customer would find out, not us.
  test "an entitlement Entitlements does not know is refused" do
    error = assert_raises(ArgumentError) { signed(entitlements: {"retention_dayz" => 10}).generate! }

    assert_match(/retention_dayz/, error.message)
    assert_match(/known: /, error.message)
  end

  test "it names every unknown entitlement, not just the first" do
    error = assert_raises(ArgumentError) do
      signed(entitlements: {"nope" => 1, "alsonope" => 2}).generate!
    end

    assert_match(/nope/, error.message)
    assert_match(/alsonope/, error.message)
  end

  test "symbol entitlement keys are accepted, since a caller in Ruby will use them" do
    licence = read_back(signed(entitlements: {retention_days: 90}).generate!)

    assert_equal({retention_days: 90}, licence.granted)
  end

  # ── The key ────────────────────────────────────────────────────────────
  #
  # Its own error class: a blank subject is a bug in the caller, a missing key
  # is an operational fact about the box. A webhook wants to tell a 500 to fix
  # in code from a deploy that never got its key.

  test "a missing signing key raises MissingKey, not ArgumentError" do
    previous = [ENV.delete("VOODU_LICENSE_PRIVATE_KEY_PEM"), ENV.delete("VOODU_LICENSE_PRIVATE_KEY")]
    ENV["VOODU_LICENSE_PRIVATE_KEY"] = "/nonexistent/nowhere.pem"

    assert_raises(LicenseToken::Signed::MissingKey) do
      LicenseToken::Signed.new(subject: "acme", days: 30).generate!
    end
  ensure
    ENV["VOODU_LICENSE_PRIVATE_KEY_PEM"], ENV["VOODU_LICENSE_PRIVATE_KEY"] = previous
  end

  test "the key can be supplied as a PEM in the environment" do
    previous = ENV["VOODU_LICENSE_PRIVATE_KEY_PEM"]
    ENV["VOODU_LICENSE_PRIVATE_KEY_PEM"] = KEY.to_pem

    licence = read_back(LicenseToken::Signed.new(subject: "acme", days: 30).generate!)

    assert_equal :valid, licence.status
  ensure
    previous.nil? ? ENV.delete("VOODU_LICENSE_PRIVATE_KEY_PEM") : ENV["VOODU_LICENSE_PRIVATE_KEY_PEM"] = previous
  end

  # Nothing is signed until every argument has been checked — the point of
  # validating first rather than trusting the caller to have read the docs.
  test "it validates before it reaches for the key" do
    previous = [ENV.delete("VOODU_LICENSE_PRIVATE_KEY_PEM"), ENV.delete("VOODU_LICENSE_PRIVATE_KEY")]
    ENV["VOODU_LICENSE_PRIVATE_KEY"] = "/nonexistent/nowhere.pem"

    assert_raises(ArgumentError) { LicenseToken::Signed.new(subject: "", days: 30).generate! }
  ensure
    ENV["VOODU_LICENSE_PRIVATE_KEY_PEM"], ENV["VOODU_LICENSE_PRIVATE_KEY"] = previous
  end
end
