# frozen_string_literal: true

require "test_helper"

# Four small breakages, all from the same shape: a second account in the
# picture. Grouped because they were reported together off one screenshot, and
# because each one is a place that assumed there was only ever one.
class HostedUiDetailsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(email: users(:owner).email) }

  def a_page
    get server_root_path(org_id: "acmeorg1", server_key: servers(:alpha).key)

    assert_response :success
  end

  # ── The avatar ────────────────────────────────────────────────────
  #
  # A broken or slow image URL made the browser paint the alt text in its
  # place — and the alt was the full display name, at the container's font
  # size, inside a 28px circle. It spilled over the topbar.

  test "the avatar image describes nothing, so a broken one paints nothing" do
    users(:owner).update!(avatar_url: "https://example.com/gone.png")

    a_page

    img = css_select("header img").first

    assert img, "the avatar image should render when a url is set"
    assert_equal "", img["alt"].to_s
  end

  test "and the circle clips whatever is inside it" do
    users(:owner).update!(avatar_url: "https://example.com/gone.png")

    a_page

    wrapper = css_select("header img").first.parent

    assert_includes wrapper["class"].to_s, "overflow-hidden"
  end

  # The letter fallback is what a viewer should see instead, so it has to stay
  # underneath rather than be replaced by the image element.
  test "the initial is still rendered behind the image" do
    users(:owner).update!(avatar_url: "https://example.com/gone.png")

    a_page

    assert_equal users(:owner).display_name[0].upcase,
      css_select("header img").first.parent.text.strip
  end

  # ── The Members nav item ──────────────────────────────────────────
  #
  # nav_href built it with server_key: nil (the route has no such segment) and
  # nav_active? built it with the current server_key — so the comparison was
  # "/acmeorg1/members" against "/acmeorg1/members?server_key=alpha" and the
  # item never lit up on its own page.

  test "Members is marked current when you are on Members" do
    get org_members_path(org_id: orgs(:acme).short_id)

    assert_response :success
    assert_select "nav a[href=?][aria-current=?]", "/acmeorg1/members", "page"
  end

  test "and is not marked current anywhere else" do
    a_page

    assert_select "nav a[href=?][aria-current=?]", "/acmeorg1/members", "page", count: 0
  end

  # ── Removing a member ─────────────────────────────────────────────

  test "removing a member asks first, and names who" do
    get org_members_path(org_id: orgs(:acme).short_id)

    # By action, not by "the form with a confirm on it" — the org manager is
    # rendered on this page too and its Delete-org form also carries one, which
    # is what the first version of this test matched.
    member = org_member_path(org_id: orgs(:acme).short_id, id: org_memberships(:contractor_in_acme).id)
    form = css_select("form[action='#{member}']").first

    assert form, "the remove form should exist"
    assert form["data-turbo-confirm"], "and should ask before removing"
    assert_includes form["data-turbo-confirm"], users(:contractor).display_name
  end

  # The server toggles beside it undo themselves in one click, so they must NOT
  # ask — a confirm on everything is a confirm on nothing.
  test "the server grant toggles do not ask" do
    get org_members_path(org_id: orgs(:acme).short_id)

    toggles = css_select("form[action*='/grant'], form[action*='/revoke']")

    assert_predicate toggles, :any?
    assert(toggles.none? { |f| f["data-turbo-confirm"] })
  end

  # ── The org manager names its accounts ────────────────────────────
  #
  # Somebody in two accounts sees both accounts' orgs in one list, and the
  # names are chosen independently by people who cannot see each other's — so
  # a collision is normal, not an edge case. Every personal org was called
  # "Default", which made it two identical rows.

  # On the ROW itself, not merely somewhere in the panel: the edit pane carries
  # the same label, so a panel-wide assertion passes with the list still
  # ambiguous — which is the half the operator actually scans.
  test "each row in the list says which account its org belongs to" do
    a_page

    row = css_select("button[data-org-select='#{orgs(:acme).id}']").first

    assert row, "acme should have a row in the org manager"
    assert_includes row.text, orgs(:acme).account.name
    assert_includes row.text, orgs(:acme).account.short_id
  end

  test "the new-org form says where the org will land" do
    a_page

    panel = css_select("#org-manager-panel").first.to_s
    own = users(:owner).owned_accounts.order(:created_at).first

    assert_includes panel, "Created in"
    assert_includes panel, own.short_id
  end

  test "the edit form says which account the org is in" do
    a_page

    assert_includes css_select("#org-manager-panel").first.to_s, "In account"
  end

  # ── The personal org is not called Default ────────────────────────

  test "a personal workspace is named after the person, org included" do
    hosted = LicenseToken.new(
      status: :valid,
      claims: {"sub" => "hosted", "exp" => 1.year.from_now.to_i, "tier" => "unlimited"}
    )
    user = User.create!(email: "thadeu.esteves@example.com", email_verified: true)

    PersonalWorkspace.ensure_for(user, license: hosted)

    assert_equal "Thadeu Esteves", user.reload.owned_accounts.sole.name
    assert_equal "Thadeu Esteves", user.active_orgs.sole.name
    assert_not_equal "Default", user.active_orgs.sole.name
  end

  # Two people arriving must not end up with the same org name, which is the
  # whole failure the old constant caused.
  test "two people do not end up with the same org name" do
    hosted = LicenseToken.new(
      status: :valid,
      claims: {"sub" => "hosted", "exp" => 1.year.from_now.to_i, "tier" => "unlimited"}
    )
    one = User.create!(email: "ana@example.com", email_verified: true)
    two = User.create!(email: "bruno@example.com", email_verified: true)

    [one, two].each { |u| PersonalWorkspace.ensure_for(u, license: hosted) }

    assert_not_equal one.reload.active_orgs.sole.name, two.reload.active_orgs.sole.name
  end
end
