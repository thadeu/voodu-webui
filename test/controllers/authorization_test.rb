# frozen_string_literal: true

require "test_helper"

# The boundary per-server grants invent: an ACTIVE MEMBER of acme, granted
# alpha and nothing else. Beta lives in the SAME org, so nothing here is tenant
# scoping — every refusal below is the grant, or the capability table.
class AuthorizationTest < ActionDispatch::IntegrationTest
  ACME = "acmeorg1"

  setup do
    sign_out
    sign_in_as(email: users(:contractor).email, name: "Contractor")
    @alpha = servers(:alpha) # granted
    @beta = servers(:beta)   # same org, NOT granted
  end

  test "a member reaches the server they were granted" do
    get server_root_path(org_id: ACME, server_key: @alpha.key)

    assert_response :success
  end

  test "a member does not reach an ungranted server in the same org" do
    [
      server_root_path(org_id: ACME, server_key: @beta.key),
      pods_path(org_id: ACME, server_key: @beta.key),
      logs_path(org_id: ACME, server_key: @beta.key),
      metrics_path(org_id: ACME, server_key: @beta.key)
    ].each do |path|
      get path

      assert_not_equal 200, response.status, "#{path} must not render"
    end
  end

  test "the sidebar lists only granted servers" do
    get server_root_path(org_id: ACME, server_key: @alpha.key)

    assert_not_includes @response.body, @beta.name
  end

  test "a forged server_id cannot reach an ungranted server" do
    get metrics_datatable_rows_path(
      org_id: ACME, server_key: @alpha.key,
      source: "hep3", scope: "fsw", name: "hep3-api", view: "messages", server_id: @beta.id
    )

    assert_response :not_found
  end

  # A PAT is the whole controller. Never a member, on any server, granted or not.
  test "a member cannot see or revoke PATs" do
    get settings_path(org_id: ACME, server_key: @alpha.key)

    assert_not_equal 200, response.status
    assert_not_includes @response.body.to_s, "pat-alpha-secret"

    delete revoke_pat_settings_path(org_id: ACME, server_key: @alpha.key, pat_id: "1")

    assert_not_equal 200, response.status
  end

  test "a member cannot register, edit or delete servers" do
    assert_no_difference("Server.count") do
      post servers_path, params: {
        server: {name: "mine", endpoint: "http://10.0.0.9:8687", pat_ciphertext: "x",
                 org_id: orgs(:acme).id}
      }
    end

    patch server_path(@alpha), params: {server: {name: "renamed"}}

    assert_equal "alpha", @alpha.reload.name

    assert_no_difference("Server.count") { delete server_path(@alpha) }
  end

  # Org-level surfaces name every server in the org, including ungranted ones —
  # AlertRule#target_label is literally "beta · web/web".
  test "a member cannot read the org's alert inventory" do
    get alerts_path(org_id: ACME, server_key: @alpha.key)

    assert_not_equal 200, response.status
    assert_not_includes @response.body.to_s, @beta.name
  end

  test "a member cannot manage alert rules or destinations" do
    get new_alert_rule_path(org_id: ACME, server_key: @alpha.key)

    assert_not_equal 200, response.status

    get alert_destinations_path(org_id: ACME, server_key: @alpha.key)

    assert_not_equal 200, response.status
  end

  # The MANAGE surface, and a member manages nothing. They still READ every
  # dashboard: the picker on /metrics lists each one as a selectable row and
  # stacks the chosen ones, which is where a dashboard is actually looked at.
  test "a member cannot reach the dashboard manager" do
    get metric_dashboards_path(org_id: ACME, server_key: @alpha.key)

    assert_not_equal 200, response.status
  end

  test "nor create a dashboard" do
    assert_no_difference "MetricDashboard.count" do
      post metric_dashboards_path(org_id: ACME, server_key: @alpha.key),
        params: {metric_dashboard: {name: "Theirs", panels: "[]"}}
    end

    assert_not_equal 200, response.status
  end

  # The guard that lets READING one on /metrics be safe — that page has no
  # authorize at all, by design, because a member is meant to watch metrics.
  # A panel naming a server this person was never granted resolves to nothing;
  # without it, opening a dashboard is a way around the per-server grant that
  # the grant exists to enforce.
  test "a panel pointed at an ungranted server renders no data for a member" do
    ungranted = servers(:beta)
    dashboard = orgs(:acme).metric_dashboards.create!(
      name: "Cross", panels: [{
        "scope_kind" => "host", "metric" => "cpu_percent", "scale" => "percent",
        "label" => "CPU", "color" => "var(--voodu-purple)", "unit" => "%",
        "server_id" => ungranted.id
      }]
    )

    data = MetricDashboardData.new(
      orgs(:acme), dashboard, visible_servers: [servers(:alpha)], range: "1h"
    )

    assert_nil data.send(:panel_server, dashboard.panels.first),
      "a panel may not resolve a server outside the viewer's own list"
  end

  # An outbound request primitive aimed at the private network the app lives in.
  test "a member cannot use the http test endpoint" do
    post metrics_datatable_http_test_path(org_id: ACME, server_key: @alpha.key),
      params: {url: "http://127.0.0.1:3000/internal/poller/servers"}

    assert_not_equal 200, response.status
  end

  test "a member cannot rename or delete the org" do
    patch org_path(orgs(:acme)), params: {org: {name: "mine now"}}, as: :turbo_stream

    assert_equal "Acme", orgs(:acme).reload.name
  end

  # Revocation must bite on the next request — the Access scope is re-read from
  # the database every time, and the recent-server list in the session must not
  # resurrect what was taken away.
  test "revoking a grant takes effect on the next request" do
    get server_root_path(org_id: ACME, server_key: @alpha.key)

    assert_response :success

    org_server_accesses(:contractor_alpha).destroy

    get server_root_path(org_id: ACME, server_key: @alpha.key)

    assert_not_equal 200, response.status
  end

  # /servers and /orgs carry no :org_id, so Current.role — which answers for the
  # org in the URL — is nil there. The capability check has to ask about the org
  # being ACTED ON, or it refuses the org's own owner.
  test "an owner registers a server from the org-less registry" do
    sign_out
    sign_in_as(email: users(:owner).email)

    get new_server_path

    assert_response :success
  end

  test "an owner renames their own org from the org-less route" do
    sign_out
    sign_in_as(email: users(:owner).email)

    patch org_path(orgs(:voidco)), params: {org: {name: "Renamed"}}, as: :turbo_stream

    assert_equal "Renamed", orgs(:voidco).reload.name
  end

  # A refusal must not bounce between `/` and the form it refused: `/` sends
  # someone with no servers to /servers/new, and /servers/new sent them back —
  # the browser gave up with "too many redirects".
  test "a refused member lands somewhere that renders, not in a loop" do
    get new_server_path

    assert_response :redirect
    assert_not_equal "/servers/new", URI(response.location).path
    assert_equal "/servers", URI(response.location).path

    # Two hops now: the org-less door resolves an org, then that registry
    # renders. What matters is that it terminates on a page.
    follow_redirect!
    follow_redirect! if response.redirect?

    assert_response :success
  end

  test "the landing never sends a member to a form they cannot use" do
    org_server_accesses(:contractor_alpha).destroy

    get root_path(org_id: nil, server_key: nil)

    assert_equal "/servers", URI(response.location).path
  end

  test "the registration form offers only orgs you administer" do
    sign_out
    sign_in_as(email: users(:contractor).email)

    get new_server_path

    assert_response :redirect
  end

  test "an invitation that was never accepted grants nothing" do
    sign_out
    sign_in_as(email: users(:invitee).email, name: "Invitee")

    get server_root_path(org_id: ACME, server_key: @alpha.key)

    assert_not_equal 200, response.status
  end
end
