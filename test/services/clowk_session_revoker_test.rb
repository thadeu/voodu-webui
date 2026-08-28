# frozen_string_literal: true

require "test_helper"

# Removing a membership denies access on the very next request — the scope is
# read from the database every time. This is the tidy-up behind that: it ends
# the Clowk session too, so a token minted before the removal cannot keep
# serving someone who still holds access to a DIFFERENT org here.
#
# Best effort by design. Every test below is really one assertion: an admin
# must be able to remove someone whatever Clowk is doing.
class ClowkSessionRevokerTest < ActiveSupport::TestCase
  SEARCH = %r{/sessions/search}
  REVOKE = %r{/sessions/}

  setup { @user = users(:contractor) }

  test "revokes every session the address has" do
    stub_request(:get, SEARCH).to_return(
      status: 200, body: {sessions: [{id: "clk_session_1"}, {id: "clk_session_2"}]}.to_json,
      headers: {"Content-Type" => "application/json"}
    )
    one = stub_request(:delete, %r{/sessions/clk_session_1}).to_return(status: 200, body: "{}")
    two = stub_request(:delete, %r{/sessions/clk_session_2}).to_return(status: 200, body: "{}")

    assert_equal :ok, ClowkSessionRevoker.revoke_for(@user)
    assert_requested one
    assert_requested two
  end

  # The removal already happened. A broker outage must not turn "you are
  # removed" into an error the admin has to retry.
  test "a broker outage is swallowed, not raised" do
    stub_request(:get, SEARCH).to_timeout

    assert_equal :unavailable, ClowkSessionRevoker.revoke_for(@user)
  end

  test "an error response is swallowed too" do
    stub_request(:get, SEARCH).to_return(status: 500, body: "boom")

    # Nothing to revoke, and nothing raised at the admin.
    assert_equal :ok, ClowkSessionRevoker.revoke_for(@user)
    assert_not_requested :delete, REVOKE
  end

  # Without a secret there is no management API to call. Saying so beats
  # pretending the sessions were ended.
  test "no secret key is a no-op, not a failure" do
    original = Clowk.config.secret_key
    Clowk.config.secret_key = nil

    assert_equal :not_configured, ClowkSessionRevoker.revoke_for(@user)
    assert_not_requested :get, SEARCH
  ensure
    Clowk.config.secret_key = original
  end

  # An address nobody proved is not identity — searching Clowk for it could
  # only match someone else's session.
  test "an unproven address is never searched for" do
    @user.update!(email_verified: false)

    assert_equal :no_identity, ClowkSessionRevoker.revoke_for(@user)
    assert_not_requested :get, SEARCH
  end

  test "a placeholder address is never searched for" do
    @user.update!(email: "x#{User::PLACEHOLDER_EMAIL_SUFFIX}", email_verified: true)

    assert_equal :no_identity, ClowkSessionRevoker.revoke_for(@user)
    assert_not_requested :get, SEARCH
  end
end
