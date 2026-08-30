# frozen_string_literal: true

require "test_helper"

# Every path through License must produce a License — never an exception.
# The product decision behind that is in the class comment: a licence that can
# raise is a licence that can take a customer's monitoring down, and a
# monitoring tool failing closed during an incident is worse than one quietly
# dropping to the free tier. So each test below is really the same assertion
# twice: the right status, and nothing thrown getting there.
class LicenseTest < ActiveSupport::TestCase
  FIXTURES = Rails.root.join("test/fixtures/files")
  KEY = OpenSSL::PKey::RSA.new(FIXTURES.join("license_test_private_key.pem").read)
  PUBLIC = OpenSSL::PKey::RSA.new(FIXTURES.join("license_test_public_key.pem").read)

  def token(claims = {}, key: KEY, alg: "RS256")
    JWT.encode({"sub" => "acme", "iat" => Time.current.to_i,
                "exp" => 30.days.from_now.to_i}.merge(claims), key, alg)
  end

  def resolve(t, **kw) = License.resolve(t, key: PUBLIC, **kw)

  test "no token is the free tier, not a failure" do
    license = resolve("")

    assert_equal :none, license.status
    assert_not license.entitled?
    assert_not license.present?
  end

  test "a signed licence inside its window is valid" do
    license = resolve(token)

    assert_equal :valid, license.status
    assert license.entitled?
    assert_equal "acme", license.customer
  end

  test "entitlement claims come back symbolised" do
    license = resolve(token({"ent" => {"orgs" => 5, "postgres" => true}}))

    assert_equal({orgs: 5, postgres: true}, license.granted)
  end

  # Expiry is a slope. Renewal paperwork runs late and an outage is not the
  # right way to find out.
  test "just past expiry is grace, and still entitled" do
    license = resolve(token({"exp" => 1.day.ago.to_i}))

    assert_equal :grace, license.status
    assert license.entitled?, "grace must keep entitlements alive"
  end

  test "past grace is lapsed, and grants nothing" do
    license = resolve(token({"exp" => (License::GRACE_PERIOD + 1.day).ago.to_i}))

    assert_equal :lapsed, license.status
    assert_not license.entitled?
    assert_empty license.granted
    # Still readable, so settings can say whose licence lapsed and when.
    assert_equal "acme", license.customer
  end

  # The customer's clock is not ours to trust to the second.
  test "a licence expiring seconds ago survives the leeway" do
    license = resolve(token({"exp" => 1.minute.ago.to_i}))

    assert_equal :valid, license.status
  end

  # ── Everything below is a refusal, and none of it may raise ────────────

  test "a licence signed by another key is invalid" do
    other = OpenSSL::PKey::RSA.new(2048)

    assert_equal :invalid, resolve(token({}, key: other)).status
  end

  test "a tampered payload is invalid" do
    header, _payload, signature = token.split(".")
    forged = Base64.urlsafe_encode64({"sub" => "pirate", "exp" => 1.year.from_now.to_i}.to_json, padding: false)

    assert_equal :invalid, resolve([header, forged, signature].join(".")).status
  end

  # alg:none is the classic JWT bypass. The verifier pins RS256, so this is a
  # refusal rather than a free licence.
  test "an unsigned licence is invalid" do
    unsigned = JWT.encode({"sub" => "pirate", "exp" => 1.year.from_now.to_i}, nil, "none")

    assert_equal :invalid, resolve(unsigned).status
  end

  test "garbage is invalid" do
    ["not-a-jwt", "a.b.c", "...", "eyJ"].each do |junk|
      assert_equal :invalid, resolve(junk).status, "#{junk.inspect} should not verify"
    end
  end

  # A token that simply omits exp must not read as "never expires" — that would
  # make one leaked licence permanent.
  test "a licence with no expiry is invalid, not eternal" do
    no_expiry = JWT.encode({"sub" => "acme", "iat" => Time.current.to_i}, KEY, "RS256")

    assert_equal :invalid, resolve(no_expiry).status
  end

  test "a missing public key is the free tier, not a crash" do
    license = License.resolve(token, key: nil)

    assert_equal :invalid, license.status
    assert_not license.entitled?
  end

  # ── Where the token comes from ─────────────────────────────────────────

  test "VOODU_LICENSE_FILE is read when the env var is empty" do
    path = Rails.root.join("tmp/license-test.jwt")
    path.write(token)
    ENV["VOODU_LICENSE_FILE"] = path.to_s

    assert_equal token.split(".").first, License.token_from_env.split(".").first
  ensure
    ENV.delete("VOODU_LICENSE_FILE")
    File.delete(path) if path&.exist?
  end

  test "an unreadable licence file is empty, not an exception" do
    ENV["VOODU_LICENSE_FILE"] = "/nonexistent/nowhere.jwt"

    assert_equal "", License.token_from_env
  ensure
    ENV.delete("VOODU_LICENSE_FILE")
  end

  # The bug this class had, pinned so it cannot come back.
  #
  # Status used to be computed once at resolve time and frozen into the object.
  # A container that booted with a valid licence therefore reported :valid for
  # as long as it ran — the licence expired on the calendar and never in the
  # process. Deriving on read is the fix, and it needs no scheduled job.
  test "status follows the clock on a licence resolved long ago" do
    license = resolve(token({"exp" => 10.days.from_now.to_i}))

    assert_equal :valid, license.status

    travel_to 15.days.from_now do
      assert_equal :grace, license.status, "the same object must notice it expired"
    end

    travel_to (10.days + License::GRACE_PERIOD + 1.day).from_now do
      assert_equal :lapsed, license.status
    end
  end
end
