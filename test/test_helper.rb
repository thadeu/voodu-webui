# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

# No test may reach the real network. localhost stays open so the system-
# test server + Chrome CDP work.
WebMock.disable_net_connect!(allow_localhost: true)

module ActiveSupport
  class TestCase
    # Tests opt in to fixtures via `fixtures :islands` etc. — no
    # global `fixtures :all` because the suite is just starting up
    # and not every model has a fixture file yet.
    parallelize(workers: 1)

    # Default: any non-localhost HTTP times out. The app's IslandHealth#probe
    # rescues that (StandardError) → island reads :offline, instantly, with
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
