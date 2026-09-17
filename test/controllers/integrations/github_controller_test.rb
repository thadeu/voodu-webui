# frozen_string_literal: true

require "test_helper"

# Connecting a customer's GitHub account to one of their servers.
#
# The two halves are asymmetric on purpose and that is what most of this file
# pins. `connect` is a normal server-scoped screen — the URL names the org, so
# the usual capability check applies. `callback` has no org in its URL, because
# GitHub redirects there knowing nothing about us, so EVERY authorization it
# performs comes out of the signed state. A callback that trusted its query
# string would let anyone who is logged in bind an installation id they read
# off somebody else's screen.
class Integrations::GithubControllerTest < ActionDispatch::IntegrationTest
  ACME = "acmeorg1"

  ENV_KEYS = %w[GITHUB_APP_ID GITHUB_APP_SLUG GITHUB_APP_PRIVATE_KEY GITHUB_WEBHOOK_SECRET].freeze

  # A real 2048-bit key, generated once for the whole file: AppJwt signs with
  # OpenSSL and a fake string would fail inside the signature rather than in
  # the code under test.
  KEY = OpenSSL::PKey::RSA.generate(2048).to_pem

  setup do
    @licensed = Rails.application.config.x.license
    @env = ENV.to_hash.slice(*ENV_KEYS)

    saas!
    configure_app!

    @org = orgs(:acme)
    @server = servers(:alpha)
  end

  teardown do
    Rails.application.config.x.license = @licensed
    ENV_KEYS.each { |key| ENV.delete(key) }
    @env.each { |key, value| ENV[key] = value }
  end

  # ── connect ────────────────────────────────────────────────────────────

  test "connect sends the operator to GitHub with a state we can verify" do
    get connect_github_path(org_id: ACME, server_key: @server.key)

    assert_response :redirect
    assert_match %r{\Ahttps://github\.com/apps/voodu-test/installations/new\?state=},
      response.location

    state = CGI.unescape(response.location.split("state=").last)
    payload = Integration::Github::State.verify(state)

    assert_equal @org.id, payload.org_id
    assert_equal @server.id, payload.server_id
  end

  test "connect refuses when the plan does not include the deploy plane" do
    free_tier!

    get connect_github_path(org_id: ACME, server_key: @server.key)

    assert_redirected_to all_servers_path(org_id: nil, server_key: nil)
    assert_match(/not part of this plan/i, flash[:alert])
  end

  test "connect refuses a member, who may read the server but not deploy from it" do
    sign_out
    sign_in_as(email: users(:contractor).email, name: "Contractor")

    get connect_github_path(org_id: ACME, server_key: @server.key)

    assert_no_match(/github\.com/, response.location.to_s)
  end

  test "connect says so when the installation has no GitHub App at all" do
    ENV_KEYS.each { |key| ENV.delete(key) }

    get connect_github_path(org_id: ACME, server_key: @server.key)

    assert_redirected_to server_root_path(org_id: ACME, server_key: @server.key)
    assert_match(/no GitHub App/i, flash[:alert])
  end

  # ── callback ───────────────────────────────────────────────────────────

  test "callback binds the installation to the org from the state" do
    assert_difference -> { Integration::Record.count }, 1 do
      get github_integration_callback_path, params: {
        state: valid_state, installation_id: "4242", setup_action: "install"
      }
    end

    integration = Integration::Record.last

    assert_equal @org.id, integration.org_id
    assert_equal "github", integration.provider
    assert_equal "4242", integration.installation_id
    assert_predicate integration, :active?
    assert_redirected_to server_root_path(org_id: ACME, server_key: @server.key)
  end

  test "callback re-binding the same account updates the row instead of adding one" do
    2.times do
      get github_integration_callback_path,
        params: {state: valid_state, installation_id: "4242"}
    end

    assert_equal 1, Integration::Record.where(org: @org, external_id: "4242").count
  end

  # The whole reason the state is signed: without it this request is a URL
  # anybody logged in could type, naming an installation they do not own.
  test "callback binds nothing when the state was tampered with" do
    assert_no_difference -> { Integration::Record.count } do
      get github_integration_callback_path,
        params: {state: "#{valid_state}x", installation_id: "4242"}
    end

    assert_redirected_to all_servers_path(org_id: nil, server_key: nil)
    assert_match(/expired/i, flash[:alert])
  end

  test "callback binds nothing with no state at all" do
    assert_no_difference -> { Integration::Record.count } do
      get github_integration_callback_path, params: {installation_id: "4242"}
    end

    assert_redirected_to all_servers_path(org_id: nil, server_key: nil)
  end

  # A state is a bearer value for the length of its TTL. It names WHO started,
  # so a link leaked to another signed-in person is inert in their hands.
  test "callback binds nothing when a different person returns with the state" do
    state = valid_state

    sign_out
    sign_in_as(email: users(:contractor).email, name: "Contractor")

    assert_no_difference -> { Integration::Record.count } do
      get github_integration_callback_path, params: {state: state, installation_id: "4242"}
    end

    assert_match(/no longer have access/i, flash[:alert])
  end

  test "callback binds nothing when GitHub is still waiting for an owner to approve" do
    assert_no_difference -> { Integration::Record.count } do
      get github_integration_callback_path,
        params: {state: valid_state, installation_id: "4242", setup_action: "request"}
    end

    assert_match(/waiting for an owner/i, flash[:alert])
  end

  test "callback binds nothing without an installation id" do
    assert_no_difference -> { Integration::Record.count } do
      get github_integration_callback_path, params: {state: valid_state}
    end

    assert_match(/did not send an installation id/i, flash[:alert])
  end

  test "callback binds nothing once the plan no longer includes the deploy plane" do
    state = valid_state
    free_tier!

    assert_no_difference -> { Integration::Record.count } do
      get github_integration_callback_path, params: {state: state, installation_id: "4242"}
    end

    assert_match(/not part of this plan/i, flash[:alert])
  end

  private

  def configure_app!
    ENV["GITHUB_APP_ID"] = "12345"
    ENV["GITHUB_APP_SLUG"] = "voodu-test"
    ENV["GITHUB_APP_PRIVATE_KEY"] = KEY
    ENV["GITHUB_WEBHOOK_SECRET"] = "s3cret"
  end

  def saas!
    Rails.application.config.x.license = LicenseToken.new(
      status: :valid,
      claims: {"sub" => "acme", "tier" => "unlimited", "exp" => 90.days.from_now.to_i}
    )
  end

  def free_tier!
    Rails.application.config.x.license = LicenseToken.new(status: :none)
  end

  def valid_state
    Integration::Github::State.generate(
      org: @org, server: @server, user: users(:owner)
    )
  end
end
