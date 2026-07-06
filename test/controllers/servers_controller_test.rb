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
end
