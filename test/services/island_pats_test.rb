# frozen_string_literal: true

require "test_helper"

# IslandPats.fetch must never leak a raw transport exception
# ("Net::ReadTimeout with #<TCPSocket:(closed)>") to the Settings page —
# an unreachable controller is a normal state, shown as a friendly line.
# WebMock (test_helper) times out the outbound call, which Voodu::Client
# wraps as a TransportError.
class IslandPatsTest < ActiveSupport::TestCase
  fixtures :orgs, :islands

  setup { @island = islands(:alpha) }

  test "an unreachable controller yields a friendly message, not the raw exception" do
    result = IslandPats.fetch(Voodu::Client.new(@island), @island)

    assert result.error?, "transport failure is a soft error, not forbidden/ok"
    assert_equal "Controller unreachable — tokens will load once it's back online.", result.error
    assert_no_match(/Net::|TCPSocket|Timeout|Faraday/, result.error.to_s, "no Ruby internals leak to the UI")
  end

  test "nil client/island short-circuits without a network call" do
    assert_not IslandPats.fetch(nil, @island).ok?
    assert_not IslandPats.fetch(Voodu::Client.new(@island), nil).ok?
  end
end
