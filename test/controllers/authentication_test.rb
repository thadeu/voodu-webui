# frozen_string_literal: true

require "test_helper"

# Sign-in is mandatory — there is no flag and no unrestricted mode. These pin
# both halves: that an anonymous visitor gets nowhere, and that the two
# machine-facing surfaces stay reachable without a session.
class AuthenticationTest < ActionDispatch::IntegrationTest
  fixtures :orgs, :servers

  INTERNAL_TOKEN = "test-internal-token-aaaaaaaaaaaaaaaa"

  test "an anonymous visitor is sent to the hosted sign-in" do
    sign_out

    get servers_path

    assert_response :redirect
    assert_match %r{/sign_in\?}, response.location
    assert_match "return_to=%2Facmeorg1%2Fservers", response.location
  end

  test "a signed-in operator reaches the app" do
    get servers_path

    assert_response :success
  end

  # The image HEALTHCHECK curls this every 30s and has no session to offer.
  # An alias, not a second door: one real sign-in path, and /login points at it.
  test "/login redirects to the engine's sign-in" do
    sign_out

    get "/login"

    assert_response :redirect
    assert_equal "/sign_in", response.location.sub(%r{\Ahttp://[^/]+}, "")
  end

  test "/login carries the return_to through" do
    sign_out

    get "/login?return_to=%2Fservers"

    assert_match "return_to=%2Fservers", response.location
  end

  # A 301 would be cached by the browser, and moving the engine's mount later
  # would strand everyone who ever visited /login.
  test "/login is a temporary redirect" do
    sign_out

    get "/login"

    assert_equal 302, response.status
  end

  test "the health endpoint stays public" do
    sign_out

    get rails_health_check_path

    assert_response :success
  end

  # A redirect here would silently stop the metrics warehouse refilling.
  test "the poller endpoint answers on its own auth, never a sign-in redirect" do
    sign_out
    ENV["POLLER_TOKEN"] = INTERNAL_TOKEN

    get internal_poller_servers_path

    assert_response :unauthorized

    get internal_poller_servers_path, headers: {"X-Voodu-Internal-Token" => INTERNAL_TOKEN}

    assert_response :success
  ensure
    ENV.delete("POLLER_TOKEN")
  end

  # A valid token in a query string would establish a session on ANY path,
  # bypassing the `state` check that makes the callback safe — and would stay
  # replayable anywhere that URL was logged.
  test "a token in the query string is refused" do
    sign_out

    get servers_path(Clowk.config.token_param => ClowkDevToken.mint(sub: "x", email: "x@example.com"))

    assert_response :bad_request
  end

  test "a token in the query string is refused even on an authenticated request" do
    get servers_path(Clowk.config.token_param => "anything")

    assert_response :bad_request
  end

  test "signing in mirrors the subject onto a local user" do
    sign_out
    sign_in_as(email: "ada@example.com", name: "Ada")

    get servers_path

    user = User.find_by(email: "ada@example.com")

    assert_not_nil user
    assert_equal "Ada", user.name
    assert_not_nil user.clowk_user_id
  end

  test "an expired token does not authenticate" do
    sign_out
    cookies[Clowk.config.cookie_key] =
      ClowkDevToken.mint(sub: "stale", email: "stale@example.com", ttl: -1.hour)

    get servers_path

    assert_response :redirect
    assert_match %r{/sign_in}, response.location
  end

  test "a token signed with the wrong secret does not authenticate" do
    sign_out
    payload = {sub: "forged", email: "forged@example.com", iss: Clowk.config.issuer,
               exp: 1.hour.from_now.to_i}
    cookies[Clowk.config.cookie_key] = JWT.encode(payload, "not-the-secret", "HS256")

    get servers_path

    assert_response :redirect
  end

  # The gem resolves `stored_user_payload || verified_request_payload`, so once
  # the Rails session exists the JWT's expiry is never re-checked. Without this
  # ceiling an open tab outlives its token indefinitely.
  test "the local hard ceiling ends a session the broker would still accept" do
    get servers_path

    assert_response :success

    travel(Authentication::SESSION_HARD_CEILING + 1.minute) do
      get servers_path

      assert_response :redirect
      assert_match %r{/sign_in}, response.location
    end
  end
end
