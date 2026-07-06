# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
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

module ActiveSupport
  class TestCase
    # Tests opt in to fixtures via `fixtures :servers` etc. — no
    # global `fixtures :all` because the suite is just starting up
    # and not every model has a fixture file yet.
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
