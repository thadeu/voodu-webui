# frozen_string_literal: true

require "test_helper"

# A member is shown what they can use, and not shown what they cannot.
#
# The rule was already written over ORG_NAV — "the endpoint refuses either way;
# this keeps the sidebar from offering a door that answers 'you need admin
# access'" — and then applied to one item out of several. Everything else drew
# the door, took the click, and answered with a red toast.
#
# Each pair below is deliberate. The FIRST half asserts the control is gone for
# a member; the SECOND asserts it is still there for an admin or owner. A test
# that only checks absence cannot tell "correctly hidden" from "selector typo",
# and this file has already produced that mistake twice in other places.
class MemberSeesNoDeadDoorsTest < ActionDispatch::IntegrationTest
  # ServerState.warehouse? decides whether a page reads pods out of the local
  # snapshot table or over HTTP, and it reads ENV on every call — which the
  # comment on that method says is exactly so a test can set it.
  #
  # This file ASSUMED it was on and never said so, so it passed only on a
  # machine whose .env carried WAREHOUSE=1 and failed on CI, which has no .env.
  # `nil` restores an unset variable, because assigning nil deletes the key.
  setup do
    @server = servers(:alpha)
    @warehouse = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"
  end

  teardown { ENV["WAREHOUSE"] = @warehouse }

  def as_member = sign_in_as(email: users(:contractor).email)

  def as_owner
    sign_out
    sign_in_as(email: users(:owner).email)
  end

  def overview
    get server_root_path(org_id: "acmeorg1", server_key: @server.key)

    assert_response :success
  end

  def nav_hrefs = css_select("nav a").map { |a| a["href"].to_s }

  # A row, not an HTTP stub: the setup above turns ServerState.warehouse? on, so
  # the detail page reads the pod out of the local snapshot table and never
  # makes a request. Stubbing Faraday produced a page rendering "not found", where the
  # header — and therefore the button under test — does not exist at all, and
  # both halves of the pair passed for the wrong reason.
  def host_panel
    {"scope_kind" => "host", "metric" => "cpu_percent", "scale" => "percent",
     "label" => "CPU", "color" => "var(--voodu-purple)", "unit" => "%",
     "server_id" => @server.id}
  end

  def stub_pod_detail
    @server.pods.create!(
      container_name: "web.0", scope: "acme", resource_name: "web", replica_id: 0,
      kind: "app", synced_at: Time.current,
      payload: {
        name: "web.0", created_at: 1.day.ago.iso8601,
        # A hash, because SpecCard digs into it. A bare "running" string reads
        # as a state and then raises on the first dig.
        state: {status: "running", running: true}
      }.to_json
    )
  end

  # ── The sidebar ───────────────────────────────────────────────────

  {"settings" => "/settings", "alerts" => "/alerts", "plugins" => "/plugins",
   "members" => "/members"}.each do |name, fragment|
    test "a member is not offered #{name}" do
      as_member
      overview

      assert(nav_hrefs.none? { |href| href.include?(fragment) }, "#{name} should be hidden")
    end

    test "an owner still is offered #{name}" do
      as_owner
      overview

      assert(nav_hrefs.any? { |href| href.include?(fragment) }, "#{name} should be visible")
    end
  end

  # ── Restarting a pod ──────────────────────────────────────────────
  #
  # This one had NO authorization at all: any member reaching the server could
  # stop and recreate a container. The button is the smaller half.

  test "a member cannot restart a pod by posting directly" do
    as_member

    post restart_pod_path(org_id: "acmeorg1", server_key: @server.key, name: "web.0")

    assert_response :redirect
    assert_match(/admin/i, flash[:alert].to_s)
  end

  test "an owner still can" do
    as_owner
    stub_request(:post, %r{/api/pat/v1/pods/web\.0/restart}).to_return(status: 200, body: "{}")

    post restart_pod_path(org_id: "acmeorg1", server_key: @server.key, name: "web.0")

    assert_response :redirect
    assert_nil flash[:alert]
  end

  # And the button, which is the half a person actually meets. Without this the
  # endpoint is safe and a member still walks through a confirmation dialog to
  # reach a refusal.
  test "a member is shown no Restart button on the pod page" do
    as_member
    stub_pod_detail

    get pod_path(org_id: "acmeorg1", server_key: @server.key, name: "web.0")

    assert_response :success
    assert_select "[aria-label=?]", "Restart web.0", count: 0
  end

  test "an owner is shown one" do
    as_owner
    stub_pod_detail

    get pod_path(org_id: "acmeorg1", server_key: @server.key, name: "web.0")

    assert_response :success
    assert_select "[aria-label=?]", "Restart web.0", minimum: 1
  end

  # ── The server registry ───────────────────────────────────────────

  test "a member is offered neither Add, Edit nor Remove" do
    as_member

    get servers_path(org_id: "acmeorg1")

    assert_response :success
    assert_select "a[href*=?]", "/servers/new", count: 0
    assert_select "a[href*=?]", "/edit", count: 0
    assert_not_includes response.body, "Remove server"
  end

  test "an owner is offered all three" do
    as_owner

    get servers_path(org_id: "acmeorg1")

    assert_response :success
    assert_select "a[href*=?]", "/servers/new", minimum: 1
    assert_select "a[href*=?]", "/edit", minimum: 1
    assert_includes response.body, "Remove server"
  end

  # An empty registry means two different things to the two of them, and
  # telling a member to "add the first one" is telling them to do what the
  # form will refuse.
  test "an empty registry tells a member the truth about why" do
    Server.where(org: orgs(:acme)).find_each(&:destroy)
    as_member

    get servers_path(org_id: "acmeorg1")

    assert_includes response.body, "No servers shared with you"
    assert_not_includes response.body, "Add the first one"
  end

  test "and still tells an owner to add one" do
    Server.where(org: orgs(:acme)).find_each(&:destroy)
    as_owner

    get servers_path(org_id: "acmeorg1")

    assert_includes response.body, "Add the first one"
  end

  # ── Deleting an org you were invited into ─────────────────────────

  test "a member is offered no Delete on an org they do not own" do
    as_member

    overview

    assert_select "button[aria-label=?]", "Delete org", count: 0
  end

  test "an owner is" do
    as_owner

    overview

    assert_select "button[aria-label=?]", "Delete org", minimum: 1
  end

  # ── Dashboards: read, do not build ────────────────────────────────
  #
  # A member watches things, and a saved dashboard is a thing to watch. What
  # they are not offered is any control that makes, renames or deletes one.

  # With a dashboard in existence, deliberately: /metrics renders the picker
  # only when there is something to pick, so without one BOTH halves of this
  # pair pass — the member's because the row is genuinely absent, the owner's
  # for the same reason, which makes the pair prove nothing.
  test "a member is not offered the Manage dashboards row in the picker" do
    orgs(:acme).metric_dashboards.create!(name: "Traffic", panels: [host_panel])
    as_member

    get metrics_path(org_id: "acmeorg1", server_key: @server.key)

    assert_response :success
    assert_not_includes response.body, "Manage dashboards"
  end

  test "an owner is offered the Manage dashboards row" do
    orgs(:acme).metric_dashboards.create!(name: "Traffic", panels: [host_panel])
    as_owner

    get metrics_path(org_id: "acmeorg1", server_key: @server.key)

    assert_includes response.body, "Manage dashboards"
  end

  # But the rows UNDER it stay: that picker is how a dashboard gets looked at,
  # and looking is the whole of what a member came for.
  test "a member still gets the dashboards themselves in the picker" do
    orgs(:acme).metric_dashboards.create!(name: "Traffic", panels: [host_panel])
    as_member

    get metrics_path(org_id: "acmeorg1", server_key: @server.key)

    assert_includes response.body, "Traffic"
  end

  # The quick-edit pencil beside the chart grid, in BOTH copies of it — the
  # page and the 30s polling frame that replaces it.
  test "a member is offered no edit pencil on the chart grid" do
    orgs(:acme).metric_dashboards.create!(name: "Traffic", panels: [host_panel], pinned: true)
    as_member

    get metrics_path(org_id: "acmeorg1", server_key: @server.key)

    assert_select "[aria-label=?]", "Edit dashboard", count: 0
  end

  test "an owner is offered the pencil" do
    orgs(:acme).metric_dashboards.create!(name: "Traffic", panels: [host_panel], pinned: true)
    as_owner

    get metrics_path(org_id: "acmeorg1", server_key: @server.key)

    assert_select "[aria-label=?]", "Edit dashboard", minimum: 1
  end

  test "and the polling frame does not hand it back on the next tick" do
    orgs(:acme).metric_dashboards.create!(name: "Traffic", panels: [host_panel], pinned: true)
    as_member

    # "metrics-charts" exactly — MetricsController compares the header to that
    # literal, and any other value falls through to the full page, where the
    # OTHER guard is what hides the pencil. The first version of this test sent
    # the wrong name and passed without ever rendering the frame.
    get metrics_path(org_id: "acmeorg1", server_key: @server.key),
      headers: {"Turbo-Frame" => "metrics-charts"}

    assert_select "[aria-label=?]", "Edit dashboard", count: 0
  end

  test "a member is not offered Build your first dashboard on the overview" do
    as_member
    overview

    assert_not_includes response.body, "Build your first dashboard"
  end

  test "an owner is offered it" do
    as_owner
    overview

    assert_includes response.body, "Build your first dashboard"
  end

  test "a member is not offered Create dashboard on the metrics page" do
    as_member

    get metrics_path(org_id: "acmeorg1", server_key: @server.key)

    assert_response :success
    assert_not_includes response.body, "Create dashboard"
  end
end
