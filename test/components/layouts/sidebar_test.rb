# frozen_string_literal: true

require "test_helper"

# The sidebar's container-wide group (License, SSO).
#
# These entries belong to the installation rather than to an org, and the two
# ways of saying that had drifted apart: nav_href built their URL with no
# org/server, while nav_active? rebuilt it WITH them — and a route that takes
# neither appends them as a query string. So the comparison was "/ops/license"
# against "/ops/license?org_id=…", and the item never lit up on its own page.
#
# Rendered directly rather than through a request because a request to /ops/*
# has no org, so the sidebar there is handed no servers and both spellings
# collapse to the same string by accident. Handing it a server is what tells the
# two apart.
class Components::Layouts::SidebarTest < ActiveSupport::TestCase
  setup do
    controller = ApplicationController.new
    request = ActionDispatch::TestRequest.create
    request.path_parameters = {controller: "ops/license", action: "index"}
    controller.request = request
    controller.response = ActionDispatch::TestResponse.new
    @view = controller.view_context

    Current.user = users(:owner)
    Current.org = orgs(:acme)
    Current.membership = org_memberships(:owner_in_acme)
    Current.role = "owner"
  end

  teardown { Current.reset }

  def render_sidebar(current_path:, server: servers(:alpha))
    Components::Layouts::Sidebar.new(
      current_path: current_path, servers: [server], current_server: server
    ).render_in(@view)
  end

  test "the licence item is current on its own page even when a server is in view" do
    html = render_sidebar(current_path: "/ops/license")

    assert_match(%r{href="/ops/license"[^>]*aria-current="page"}, html)
  end

  test "the sign-in item is current on its own page even when a server is in view" do
    html = render_sidebar(current_path: "/ops/sso")

    assert_match(%r{href="/ops/sso"[^>]*aria-current="page"}, html)
  end

  # The other half: being on one must not light the other.
  test "the two container-wide items do not light up together" do
    html = render_sidebar(current_path: "/ops/license")

    assert_no_match(%r{href="/ops/sso"[^>]*aria-current="page"}, html)
  end

  # And their hrefs carry no org or server, which is what makes them bookmarkable
  # as installation screens rather than as a view of one org.
  test "the container-wide links carry no org or server in their URL" do
    html = render_sidebar(current_path: "/ops/license")

    assert_match(%r{href="/ops/license"}, html)
    assert_no_match(%r{href="/ops/license\?}, html)
  end
end
