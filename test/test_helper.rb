# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "minitest/mock"

# The suite runs LICENSED, and has to.
#
# Almost everything here exercises multi-tenancy — several orgs, invitations,
# per-server grants — which the free tier caps at one org and zero invites. Left
# unlicensed, hundreds of tests would fail for a reason none of them are about.
#
# Set after the environment loads because License is autoloaded and cannot be
# named from config/environments. Tests that are ABOUT the limits build their
# own Entitlements or replace this value for the duration.
Rails.application.config.x.license = LicenseToken.new(
  status: :valid, claims: {"sub" => "test-suite", "exp" => 10.years.from_now.to_i}
)
# The suite's own signing secret, for the suite's own harness.
#
# config/initializers/clowk.rb deliberately leaves Clowk.config.secret_key nil
# when the operator supplied none — a default there would be a published
# credential, because the gem's HS256 path checks a signature and no audience.
# That rule is about the APPLICATION's configuration, and it stays.
#
# The suite still has to sign in, and ClowkDevToken mints HS256, so it needs a
# secret to exist. Generated per run rather than written down: nothing here is
# a value anybody could know, nothing reaches production, and the initializer
# keeps saying nil for every environment it configures.
Clowk.config.secret_key ||= SecureRandom.hex(32)

require "rails/test_help"
require "webmock/minitest"

# No test may reach the real network. localhost stays open so the system-
# test server + Chrome CDP work.
WebMock.disable_net_connect!(allow_localhost: true)

# Org routing (M1): every per-server route now nests under /:org_id. Rather
# than thread `org_id:` through the hundreds of existing `*_path(server_key:)`
# call sites, default it globally for the TEST env — every server fixture
# (alpha, beta) belongs to the `acme` org (short_id below). Real requests still
# override this from the URL's :org_id path segment, so the app's own routing
# isn't masked; this only fills in the segment for bare helper calls in tests.
Rails.application.routes.default_url_options[:org_id] = "acmeorg1"

# Sign-in for tests. NOT a stub: this mints a real HS256 token with the secret
# the app is configured to verify with, and sets the real cookie — so
# Clowk::Middleware::TokenExtractor reads it, Clowk::JwtVerifier verifies it and
# Clowk::Authenticable persists the session exactly as in production. Nothing
# about the gem is mocked.
module AuthenticationTestHelper
  DEFAULT_EMAIL = "operator@example.com"

  def sign_in_as(email: DEFAULT_EMAIL, name: "Operator", email_verified: true, sub: nil)
    subject = sub || "test-#{Digest::SHA256.hexdigest(email)[0, 16]}"
    cookies[Clowk.config.cookie_key] = ClowkDevToken.mint(
      sub: subject, email: email, name: name, email_verified: email_verified
    )

    User.provision_from_clowk!(
      sub: subject, email: email, name: name, email_verified: email_verified, provider: "dev"
    )
  end

  def sign_out
    cookies.delete(Clowk.config.cookie_key)
  end
end

module ActionDispatch
  class IntegrationTest
    include AuthenticationTestHelper

    # Authentication is mandatory, so an unauthenticated request only ever
    # proves that the sign-in redirect works. Every integration test starts
    # signed in; the ones that care about the boundary sign out first.
    setup { sign_in_as }
  end
end

module ActiveSupport
  class TestCase
    # `fixtures :all` now, not opt-in: orgs reference accounts, accounts
    # reference users, and memberships tie the three together — loading any one
    # of them alone trips a foreign key. Per-test `fixtures :x` declarations are
    # harmless and stay as documentation of what each file leans on.
    # Namespaced models: Rails would classify `org_memberships` as
    # OrgMembership, find nothing, and fall back to a raw table insert — which
    # silently stops resolving `server: alpha` style label references.
    set_fixture_class org_memberships: "Org::Membership",
      org_server_accesses: "Org::ServerAccess"

    fixtures :all

    parallelize(workers: 1)

    # Default: any non-localhost HTTP times out. The app's ServerHealth#probe
    # rescues that (StandardError) → server reads :offline, instantly, with
    # no real connect. Registered per-test because webmock/minitest resets
    # stubs around each test, so a load-time registration would be wiped.
    # Override with a specific stub when a test needs an online/green response.
    setup do
      WebMock.stub_request(
        :any,
        ->(uri) { !%w[localhost 127.0.0.1 0.0.0.0].include?(uri.host.to_s) }
      ).to_timeout
    end
  end
end
