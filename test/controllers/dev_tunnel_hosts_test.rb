# frozen_string_literal: true

require "test_helper"

# The host allow-list that lets a GitHub webhook reach a laptop.
#
# Rails refuses an unrecognised Host header — the guard against DNS rebinding,
# and it is right to have. Testing the deploy plane end to end needs a tunnel,
# whose hostname is generated per session and cannot be configured ahead of
# time. So development allows a PATTERN, and this file keeps the pattern from
# being sloppy and keeps it out of production.
#
# Asserted against the CONFIG FILE's text rather than the loaded config: these
# patterns only exist in the development environment, and a test running in the
# test environment cannot see them. Reading the file is the honest way to check
# something that is true somewhere else — a runtime assertion here would skip,
# and a skipped test guards nothing.
class DevTunnelHostsTest < ActiveSupport::TestCase
  DEV = Rails.root.join("config/environments/development.rb").read
  PROD = Rails.root.join("config/environments/production.rb").read

  # An unanchored `.trycloudflare.com` also matches
  # `trycloudflare.com.attacker.example` — the classic suffix-match hole, and
  # the whole reason the guard exists.
  test "the tunnel patterns are anchored at both ends" do
    assert_includes DEV, 'config.hosts << /\A[a-z0-9-]+\.trycloudflare\.com\z/'
    assert_includes DEV, 'config.hosts << /\A[a-z0-9-]+\.ngrok(-free)?\.(app|io|dev)\z/'
  end

  # DEVELOPMENT ONLY. A wildcard in production turns the protection off for
  # every customer to save a developer one line.
  test "production has no tunnel wildcard" do
    assert_not_includes PROD, "trycloudflare"
    assert_not_includes PROD, "ngrok"
    assert_not_includes PROD, "config.hosts <<"
  end

  # The behavior those patterns are meant to have, checked directly. Written
  # out here rather than read from the config so the test states the intent
  # instead of echoing the implementation.
  test "the shape allows a generated tunnel and refuses a suffix attack" do
    tunnel = /\A[a-z0-9-]+\.trycloudflare\.com\z/

    assert_match tunnel, "resolve-men-heart-validation.trycloudflare.com"
    assert_no_match tunnel, "trycloudflare.com.attacker.example"
    assert_no_match tunnel, "evil.example"
    assert_no_match tunnel, "sub.domain.trycloudflare.com"
  end
end
