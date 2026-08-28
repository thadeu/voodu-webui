# frozen_string_literal: true

require "test_helper"

# The attacker here is a real OWNER of their own org — the highest role there
# is. So nothing they are refused can be mistaken for a role check doing the
# work: every refusal below is tenant scoping, and only tenant scoping.
#
# What is actually at stake is not a chart. Reaching another tenant's server
# reaches its PAT, and a PAT is the whole controller: deploy, exec, logs. The
# `/settings` and `PATCH /servers/:key` tests are the two that matter most.
class CrossTenantTest < ActionDispatch::IntegrationTest
  ACME = "acmeorg1"

  setup do
    sign_out
    sign_in_as(email: users(:outsider).email, name: "Outsider") # owner of globex
    @alpha = servers(:alpha)   # acme
    @gamma = servers(:gamma)   # globex — theirs
  end

  # Not merely readable: `update` accepts an endpoint, so this is a takeover —
  # repoint the server at a box you control, supply a PAT that box accepts, and
  # the poller starts writing your data into their warehouse within a minute
  # while their real controller goes dark.
  #
  # Addressed through the attacker's OWN org, which is the sharp version: they
  # legitimately reach /globex22/servers, so nothing bounces them at the org
  # gate — the refusal has to come from the server lookup itself.
  #
  # (Naming acme's org in the path is refused earlier and more bluntly: they
  # hold no membership there, so the org does not resolve at all.)
  test "another org's server is not readable, editable or deletable" do
    get "/globex22/servers/#{@alpha.key}/edit"

    assert_response :not_found

    patch "/globex22/servers/#{@alpha.key}", params: {server: {endpoint: "http://evil.example:8687"}}

    assert_response :not_found
    assert_equal "http://10.0.0.1:8687", @alpha.reload.endpoint

    assert_no_difference("Server.count") { delete "/globex22/servers/#{@alpha.key}" }
  end

  test "an org you do not belong to does not resolve at all" do
    get "/#{ACME}/servers"

    assert_response :redirect
    assert_not_includes @response.body.to_s, @alpha.name
  end

  test "the server registry lists only your own" do
    get "/globex22/servers"

    assert_response :success
    assert_includes @response.body, @gamma.name
    assert_not_includes @response.body, @alpha.name
    assert_not_includes @response.body, @alpha.endpoint
  end

  # Even for a server they legitimately own: moving it would carry its whole
  # warehouse history — the metrics DB, the HEP tables and storage/logs are all
  # filed under the unchanged integer id — into another tenant's org.
  test "a server cannot be moved between orgs by mass assignment" do
    patch server_path(@gamma), params: {
      server: {name: @gamma.name, endpoint: @gamma.endpoint, org_id: orgs(:acme).id}
    }

    assert_equal orgs(:globex).id, @gamma.reload.org_id
  end

  test "another org's pages are unreachable by URL" do
    [
      server_root_path(org_id: ACME, server_key: @alpha.key),
      pods_path(org_id: ACME, server_key: @alpha.key),
      logs_path(org_id: ACME, server_key: @alpha.key),
      metrics_path(org_id: ACME, server_key: @alpha.key),
      alerts_path(org_id: ACME, server_key: @alpha.key)
    ].each do |path|
      get path

      assert_not_equal 200, response.status, "#{path} must not render"
    end
  end

  # The one that matters most: a PAT is the controller.
  test "another org's PATs cannot be listed or revoked" do
    get settings_path(org_id: ACME, server_key: @alpha.key)

    assert_not_equal 200, response.status
    assert_not_includes @response.body.to_s, "pat-alpha-secret"

    delete revoke_pat_settings_path(org_id: ACME, server_key: @alpha.key, pat_id: "1")

    assert_not_equal 200, response.status
  end

  test "another org is not renameable or deletable" do
    patch org_path(orgs(:acme)), params: {org: {name: "pwned"}}, as: :turbo_stream

    assert_response :not_found
    assert_equal "Acme", orgs(:acme).reload.name

    assert_no_difference("Org.count") do
      delete org_path(orgs(:voidco)), as: :turbo_stream
    end
  end

  # Catches two leaks in one assertion: the org NAME in the switcher, and the
  # raw UUID primary key the option markup carries.
  test "the org switcher lists only orgs you belong to" do
    get server_root_path(org_id: "globex22", server_key: @gamma.key)

    assert_response :success
    assert_not_includes @response.body, "Acme"
    assert_not_includes @response.body, orgs(:acme).id
  end

  test "the command palette will not serve another org" do
    get command_palette_path(format: :json, org: ACME)

    body = @response.body.to_s

    assert_not_includes body, @alpha.name
    assert_not_includes body, @alpha.key
  end

  test "a forged server_id cannot cross orgs on the read endpoints" do
    get metrics_datatable_rows_path(
      org_id: "globex22", server_key: @gamma.key,
      source: "hep3", scope: "fsw", name: "hep3-api", view: "messages", server_id: @alpha.id
    )

    assert_response :not_found
  end

  # A grant row that should never have existed — the model refuses to create
  # one, so this bypasses validation to prove the READ is scoped twice and the
  # row is inert on its own.
  test "a cross-org grant row grants nothing" do
    forged = Org::ServerAccess.new(
      membership: org_memberships(:outsider_in_globex), server: @alpha, org: orgs(:globex)
    )
    forged.save!(validate: false)

    get server_root_path(org_id: ACME, server_key: @alpha.key)

    assert_not_equal 200, response.status

    get server_root_path(org_id: "globex22", server_key: @alpha.key)

    assert_not_equal 200, response.status
  end

  # Adding sign-in must not have made a browser session sufficient for the
  # machine plane — it hands out every tenant's decrypted PAT.
  test "the poller roster still needs its own token" do
    ENV["POLLER_TOKEN"] = "test-internal-token-aaaaaaaaaaaaaaaa"

    get internal_poller_servers_path

    assert_response :unauthorized
  ensure
    ENV.delete("POLLER_TOKEN")
  end
end
