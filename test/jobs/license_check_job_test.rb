# frozen_string_literal: true

require "test_helper"

# The job reports; it never decides.
#
# Expiry is derived from the clock on every read, so this running or not running
# changes nothing about what is in force. That is the property worth pinning —
# a scheduled task that gated entitlements would mean the product is wrong for
# up to a day, with a queue that can fall behind holding it up.
class LicenseCheckJobTest < ActiveJob::TestCase
  FIXTURES = Rails.root.join("test/fixtures/files")
  KEY = OpenSSL::PKey::RSA.new(FIXTURES.join("license_test_private_key.pem").read)
  PUBLIC = OpenSSL::PKey::RSA.new(FIXTURES.join("license_test_public_key.pem").read)

  setup do
    @env = ENV.delete("VOODU_LICENSE")
    @configured = Rails.application.config.x.license
    Rails.application.config.x.license = nil
    License.instance_variable_set(:@public_key, PUBLIC)
  end

  teardown do
    ENV["VOODU_LICENSE"] = @env if @env
    Rails.application.config.x.license = @configured
    License.remove_instance_variable(:@public_key) if License.instance_variable_defined?(:@public_key)
  end

  def activate(exp:, iat: Time.current)
    token = JWT.encode({"sub" => "acme", "iat" => iat.to_i, "exp" => exp.to_i}, KEY, "RS256")
    LicenseKey.activate!(token)
  end

  test "no licence is nothing to do" do
    assert_nothing_raised { LicenseCheckJob.perform_now }
  end

  test "it records that the check ran" do
    activate(exp: 365.days.from_now)

    assert_nil LicenseKey.current.last_checked_at

    LicenseCheckJob.perform_now

    assert_not_nil LicenseKey.current.reload.last_checked_at
  end

  # The whole point of the job's design: it changes nothing.
  test "running it does not alter what is in force" do
    activate(exp: 365.days.from_now)
    before = Entitlements.current.table

    LicenseCheckJob.perform_now

    assert_equal before, Entitlements.current.table
    assert_equal 1, LicenseKey.count, "it must not delete or replace keys"
  end

  test "and NOT running it does not delay expiry" do
    activate(exp: 1.day.from_now)

    travel_to (1.day + License::GRACE_PERIOD + 1.day).from_now do
      # No job has run in that window. The licence is lapsed anyway.
      assert_equal :lapsed, License.current.status
      assert Entitlements.current.free?
    end
  end

  # Reads the real logger rather than a double: what matters is the text an
  # operator greps for, and a double would pass while the message went nowhere.
  def captured_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  test "it warns as expiry approaches" do
    activate(exp: 3.days.from_now)

    assert_includes captured_log { LicenseCheckJob.perform_now }, "expires in 3 days"
  end

  test "it says nothing while expiry is far away" do
    activate(exp: 300.days.from_now)

    assert_not_includes captured_log { LicenseCheckJob.perform_now }, "expires in"
  end

  test "it is loud when a stored licence stops verifying" do
    activate(exp: 365.days.from_now)
    # What an upgrade that rotated the signing key would look like.
    License.instance_variable_set(:@public_key, OpenSSL::PKey::RSA.new(2048).public_key)

    assert_includes captured_log { LicenseCheckJob.perform_now }, "no longer verifies"
  end
end
