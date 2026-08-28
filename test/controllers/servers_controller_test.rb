# frozen_string_literal: true

require "test_helper"

# /servers is the SERVER-LESS landing (no org/server in the URL), but its
# sidebar + server list build per-server links (`/:org_id/:server_key/…`).
# Rendering the whole page exercises every one of those path helpers, so a
# missing org_id surfaces as a 500 here — the regression guard for the M1
# routes that made org_id required (default_url_options can't fill it in when
# the URL itself carries no org).
class ServersControllerTest < ActionDispatch::IntegrationTest
  fixtures :orgs, :servers

  test "index renders the server list with org-scoped per-server links" do
    get servers_path

    assert_response :success
    alpha = servers(:alpha)
    # The sidebar + list link each server at /:org_id/:server_key — the org
    # short_id must ride along (this is exactly what regressed).
    assert_includes @response.body, "/#{alpha.org.short_id}/#{alpha.key}"
  end

  test "new renders the add-server form (org picker + endpoint + PAT)" do
    get new_server_path

    assert_response :success
    assert_includes @response.body, "Add server"
    assert_includes @response.body, "org-select"
  end

  # The registry is org-scoped: a page that lists servers has to say whose.
  test "the org-less door resolves an org and redirects to its registry" do
    get "/servers"

    assert_response :redirect
    assert_match %r{/[a-zA-Z0-9]{8}/servers\z}, URI(response.location).path
  end

  test "the registry lists only the org in the URL" do
    get "/acmeorg1/servers"

    assert_response :success
    assert_includes @response.body, servers(:alpha).name
    assert_not_includes @response.body, servers(:gamma).name
  end

  # Stepping onto the registry used to throw away the org switcher and the
  # crumb trail — the two controls still valid there, and the ones you reach for
  # to get back. Only the server-dependent chips should disappear.
  test "the topbar keeps the org switcher and crumbs with no server selected" do
    get "/acmeorg1/servers"

    assert_includes @response.body, orgs(:acme).name
    assert_includes @response.body, %(data-controller="org-manager")
    assert_includes @response.body, "no server selected"
  end

  test "the server-dependent chips are the only thing that goes" do
    get "/acmeorg1/servers"

    assert_not_includes @response.body, "uptime"
    assert_not_includes @response.body, "server-status-pill"
  end

  test "the brand mark links home" do
    get "/acmeorg1/servers"

    assert_match %r{<a[^>]+href="/"[^>]*>\s*<img[^>]+mark-mint}, @response.body
  end
end
