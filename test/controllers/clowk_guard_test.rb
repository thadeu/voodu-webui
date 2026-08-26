# frozen_string_literal: true

require "test_helper"

# Operator sign-in is a boot-time switch (ClowkAuth reads config.x, written
# once by the initializer), so these drive it through the predicate instead of
# re-booting the app with a different environment. What matters is the
# before_action's behaviour on both sides of the flag, and — just as much —
# what it must NOT touch.
class ClowkGuardTest < ActionDispatch::IntegrationTest
  fixtures :orgs, :servers

  INTERNAL_TOKEN = "test-internal-token-aaaaaaaaaaaaaaaa"

  test "switched off, pages render with no session at all" do
    get servers_path

    assert_response :success
  end

  test "switched on, an anonymous visitor goes to the hosted sign-in" do
    with_clowk_auth do
      get servers_path

      assert_response :redirect
      assert_match %r{/clowk/sign_in\?}, response.location
    end
  end

  test "switched on, the sign-in carries where the visitor was headed" do
    with_clowk_auth do
      get servers_path

      assert_match "return_to=%2Fservers", response.location
    end
  end

  # The image HEALTHCHECK curls /up every 30s and has no session to offer.
  # rails/health#show is not an ApplicationController subclass, which is what
  # keeps it out of the guard — pinned here so a future "just move the health
  # route under ApplicationController" doesn't turn every container unhealthy.
  test "the health endpoint stays public with auth on" do
    with_clowk_auth do
      get rails_health_check_path

      assert_response :success
    end
  end

  # The Go poller talks to /internal/poller/* with a token, not a browser
  # session. A redirect here would stop the warehouse refilling and show up as
  # servers going offline — the failure this guard must never cause.
  test "the poller endpoint answers on its own auth, never a sign-in redirect" do
    ENV["POLLER_TOKEN"] = INTERNAL_TOKEN

    with_clowk_auth do
      get internal_poller_servers_path

      assert_response :unauthorized

      get internal_poller_servers_path,
        headers: {"X-Voodu-Internal-Token" => INTERNAL_TOKEN}

      assert_response :success
      assert_equal 1, JSON.parse(response.body)["version"]
    end
  ensure
    ENV.delete("POLLER_TOKEN")
  end

  private

  # Flips the same switch the initializer writes at boot, rather than stubbing
  # the predicate — so these exercise the real path from config.x through
  # ClowkAuth.enabled? into the before_action.
  def with_clowk_auth
    previous = Rails.application.config.x.clowk_auth_enabled
    Rails.application.config.x.clowk_auth_enabled = true

    yield
  ensure
    Rails.application.config.x.clowk_auth_enabled = previous
  end
end
