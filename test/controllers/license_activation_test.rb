# frozen_string_literal: true

require "test_helper"

# The upgrade path, end to end: free tier → buy → paste → Enterprise, with no
# restart and no env var. This is the flow the whole feature exists for, so it
# is tested as a flow rather than as three units.
class LicenseActivationTest < ActionDispatch::IntegrationTest
  FIXTURES = Rails.root.join("test/fixtures/files")
  KEY = OpenSSL::PKey::RSA.new(FIXTURES.join("license_test_private_key.pem").read)
  PUBLIC = OpenSSL::PKey::RSA.new(FIXTURES.join("license_test_public_key.pem").read)

  setup do
    sign_out
    sign_in_as(email: users(:owner).email)

    # Out of the way, so the database is the only source under test.
    @env = ENV.delete("VOODU_LICENSE")
    @configured = Rails.application.config.x.license
    Rails.application.config.x.license = nil

    # The suite ships a test keypair; the app verifies against the production
    # public key, so point it at ours for the duration.
    License.instance_variable_set(:@public_key, PUBLIC)
  end

  teardown do
    ENV["VOODU_LICENSE"] = @env if @env
    Rails.application.config.x.license = @configured
    License.remove_instance_variable(:@public_key) if License.instance_variable_defined?(:@public_key)
  end

  def token(claims = {})
    JWT.encode({"sub" => "acme-corp", "iat" => Time.current.to_i,
                "exp" => 365.days.from_now.to_i}.merge(claims), KEY, "RS256")
  end

  def settings_url
    settings_path(org_id: "acmeorg1", server_key: servers(:alpha).key)
  end

  test "an operator starts on the free tier" do
    assert Entitlements.current.free?
  end

  test "pasting a licence activates Enterprise on the next request" do
    assert_difference("LicenseKey.count", 1) do
      post license_path, params: {license_token: token, return_to: settings_url}
    end

    assert_redirected_to settings_url
    assert_match(/activated/i, flash[:notice])

    # The point: no restart, no env var, and the entitlements are live.
    assert_not Entitlements.current.free?
    assert Entitlements.current.postgres?
    assert_equal "acme-corp", License.current.customer
  end

  test "the activation is recorded with who did it" do
    post license_path, params: {license_token: token, return_to: settings_url}

    key = LicenseKey.current

    assert_equal "acme-corp", key.subject
    assert_equal users(:owner).id, key.activated_by_id
  end

  # A row that never grants anything would sit in Settings looking like a
  # licence and behaving like nothing.
  test "a token that does not verify is refused and not stored" do
    forged = JWT.encode({"sub" => "pirate", "exp" => 1.year.from_now.to_i},
      OpenSSL::PKey::RSA.new(2048), "RS256")

    assert_no_difference("LicenseKey.count") do
      post license_path, params: {license_token: forged}
    end

    assert_match(/could not be verified/i, flash[:alert])
    assert Entitlements.current.free?
  end

  test "an empty paste is told what to paste" do
    assert_no_difference("LicenseKey.count") { post license_path, params: {license_token: "  "} }

    assert_match(/paste the licence token/i, flash[:alert])
  end

  # Renewal is the same act as activation, and the newer token must win.
  test "renewing replaces which licence is in force" do
    post license_path, params: {license_token: token({"sub" => "old", "iat" => 2.days.ago.to_i})}

    assert_equal "old", License.current.customer

    post license_path, params: {license_token: token({"sub" => "renewed"})}

    assert_equal "renewed", License.current.customer
    assert_equal 2, LicenseKey.count, "the history is kept"
  end

  # Expired is expired. Re-pasting the same lapsed token buys nothing — the only
  # way out is a new one, which is what makes the exp claim mean anything.
  test "re-activating a lapsed licence does not revive it" do
    post license_path, params: {license_token: token({"exp" => 400.days.ago.to_i, "iat" => 800.days.ago.to_i})}

    assert_equal :lapsed, License.current.status
    assert Entitlements.current.free?
  end

  test "only an owner may activate" do
    sign_out
    sign_in_as(email: users(:contractor).email)

    assert_no_difference("LicenseKey.count") { post license_path, params: {license_token: token, return_to: settings_url} }

    assert_not_equal 200, response.status
  end

  # ── The history ────────────────────────────────────────────────────────
  #
  # The rows were always being written and nothing showed them. What they answer
  # is what support actually gets asked: when did this become Enterprise, under
  # whose name, and who pasted it.

  test "every activation is listed, newest first, with who did it" do
    post license_path, params: {license_token: token({"sub" => "first-purchase", "iat" => 3.days.ago.to_i}),
                                return_to: settings_url}
    post license_path, params: {license_token: token({"sub" => "renewal"}), return_to: settings_url}

    get settings_url

    assert_response :success
    assert_includes response.body, "License history"
    assert_includes response.body, "first-purchase"
    assert_includes response.body, "renewal"
    assert_includes response.body, "in force"
    assert_includes response.body, users(:owner).display_name
  end

  test "only the licence in force is marked as such" do
    post license_path, params: {license_token: token({"sub" => "acme-2025", "iat" => 3.days.ago.to_i}),
                                return_to: settings_url}
    post license_path, params: {license_token: token({"sub" => "acme-2026"}), return_to: settings_url}

    get settings_url
    body = response.body

    assert_operator body.index("acme-2026"), :<, body.index("acme-2025"), "newest first"
    assert_equal 1, body.scan("in force").size, "exactly one row is in force"
  end

  # Nothing to show is nothing shown, rather than an empty heading.
  test "no history section before the first activation" do
    get settings_url

    assert_not_includes response.body, "License history"
  end
end
