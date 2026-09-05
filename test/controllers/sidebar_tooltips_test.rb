# frozen_string_literal: true

require "test_helper"

# A collapsed sidebar is nine identical-looking icons, and the label is the
# only thing telling them apart.
#
# `title` alone was not enough: the OS tooltip waits about a second and renders
# in the desktop's style, so every guess costs a beat. At that price an
# operator expands the sidebar again, which makes the collapse pointless.
class SidebarTooltipsTest < ActionDispatch::IntegrationTest
  ACME = "acmeorg1"

  setup { @server = servers(:alpha) }

  test "every nav item carries a drawn tooltip and the native one" do
    get server_root_path(org_id: ACME, server_key: @server.key)

    assert_response :success

    aside = response.body[%r{<aside.*?</aside>}m]

    assert_not_nil aside
    assert_includes aside, %(title="Pods")
    assert_includes aside, %(role="tooltip")
  end

  # ONLY while collapsed. Expanded, the label is right there — a tooltip
  # repeating visible text is noise that follows the cursor.
  test "the tooltip is drawn only when the sidebar is collapsed" do
    get server_root_path(org_id: ACME, server_key: @server.key)

    tooltip = response.body[/<span role="tooltip"[^>]*>/]

    assert_not_nil tooltip
    assert_includes tooltip, "vmd:group-data-[collapsed]:block"
    assert_includes tooltip, "hidden"
  end

  # The accessible NAME lives on the trigger, not on the tooltip. The visible
  # label span is `display: none` when collapsed, and a display-none node is
  # out of the accessibility tree — so without this the icon would have no
  # name exactly when it is alone.
  test "a collapsed nav item still has an accessible name" do
    get server_root_path(org_id: ACME, server_key: @server.key)

    aside = response.body[%r{<aside.*?</aside>}m]

    assert_includes aside, %(aria-label="Logs")

    # And the tooltip is decoration, so it is not announced a second time.
    assert_includes aside, %(role="tooltip" aria-hidden="true")
    assert_not_includes aside, "aria-describedby"
  end

  test "the tooltip points at the icon" do
    get server_root_path(org_id: ACME, server_key: @server.key)

    assert_includes response.body, "rotate-45"
  end

  # A NAMED group. The aside owns the unnamed one — it is what every
  # `group-data-[collapsed]:*` on the page reads — so reusing it here would
  # make one item's hover look like the whole sidebar's and pop every tooltip
  # at once.
  test "the item hover uses its own group, not the sidebar's" do
    get server_root_path(org_id: ACME, server_key: @server.key)

    aside = response.body[%r{<aside.*?</aside>}m]

    assert_includes aside, "group/nav"
    assert_includes aside, "group-hover/nav:opacity-100"
  end

  # The tooltip sits outside the sidebar's width, so anything clipping on the
  # way up would hide it. Pinned because the failure is invisible in markup —
  # everything renders, nothing shows.
  test "nothing between the tooltip and the page clips it" do
    get server_root_path(org_id: ACME, server_key: @server.key)

    aside_open = response.body[/<aside[^>]*>/]

    assert_not_nil aside_open
    assert_not_includes aside_open, "overflow-hidden"
    assert_not_includes aside_open, "overflow-y-auto"
  end
end
