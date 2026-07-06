# frozen_string_literal: true

require "test_helper"

# ServerPats.fetch must never leak a raw transport exception
# ("Net::ReadTimeout with #<TCPSocket:(closed)>") to the Settings page —
# an unreachable controller is a normal state, shown as a friendly line.
# WebMock (test_helper) times out the outbound call, which Voodu::Client
# wraps as a TransportError.
class ServerPatsTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  setup { @server = servers(:alpha) }

  test "an unreachable controller yields a friendly message, not the raw exception" do
    result = ServerPats.fetch(Voodu::Client.new(@server), @server)

    assert result.error?, "transport failure is a soft error, not forbidden/ok"
    assert_equal "Controller unreachable — tokens will load once it's back online.", result.error
    assert_no_match(/Net::|TCPSocket|Timeout|Faraday/, result.error.to_s, "no Ruby internals leak to the UI")
  end

  test "nil client/server short-circuits without a network call" do
    assert_not ServerPats.fetch(nil, @server).ok?
    assert_not ServerPats.fetch(Voodu::Client.new(@server), nil).ok?
  end
end
