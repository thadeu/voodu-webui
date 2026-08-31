# frozen_string_literal: true

require "test_helper"

# Who may configure the INSTALLATION — its licence and its sign-in.
#
# These two screens carry no :org_id, and that is the whole difficulty: the
# capability table normally answers about the org in the URL, so on a route with
# no org it answered nil and denied everyone. The licence an operator had paid
# for could not be installed by anybody through the browser, and the SSO screen
# redirected to itself until the browser gave up.
#
# So every test below names the org it does or does not pass through, and the
# bare-path cases matter most: that is the shape a real click produces.
class OpsAuthorizationTest < ActionDispatch::IntegrationTest
  # The paths as the account menu builds them — no org segment, no query.
  LICENSE = "/ops/license"
  SSO = "/ops/sso"

  # test_helper pins a GLOBAL default_url_options[:org_id] so the hundreds of
  # server-scoped helper calls elsewhere need no org threaded through them. On
  # these routes that global is a lie: a real /ops/* request has no org in its
  # path, so ApplicationController#default_url_options contributes nothing and
  # any helper needing :org_id raises UrlGenerationError.
  #
  # It masked exactly that — the pages 500'd in a browser while these tests
  # rendered them fine. Dropped here so every request below generates URLs the
  # way the running app does.
  setup do
    @pinned_org = Rails.application.routes.default_url_options.delete(:org_id)
  end

  teardown do
    Rails.application.routes.default_url_options[:org_id] = @pinned_org if @pinned_org
  end

  # The regression that shipped. Owner of acme, following the menu link, was
  # told they needed owner access to do that.
  test "an owner opens the licence screen with no org in the URL" do
    sign_in_as(email: users(:owner).email)

    get LICENSE

    assert_response :success
  end

  test "an owner opens the sign-in screen with no org in the URL" do
    sign_in_as(email: users(:owner).email)

    get SSO

    assert_response :success
  end

  # The screens are not merely reachable — they must carry their controls. Both
  # bodies gate on the same capability, and a page that opens empty is the same
  # bug wearing a 200.
  test "the licence screen renders its activation form, not an empty page" do
    sign_in_as(email: users(:owner).email)

    get LICENSE

    assert_select "form[action=?]", LICENSE
  end

  test "the sign-in screen renders its form, not an empty page" do
    sign_in_as(email: users(:owner).email)

    get SSO

    assert_select "form[action=?]", SSO
  end

  # A member holds no such capability in any org, and must still be refused —
  # the fix widened WHERE the role is looked for, not WHICH role is required.
  test "a member is refused the licence screen" do
    sign_in_as(email: users(:contractor).email)

    get LICENSE

    assert_redirected_to all_servers_path
    assert_match(/owner access/, flash[:alert])
  end

  test "a member is refused the sign-in screen" do
    sign_in_as(email: users(:contractor).email)

    get SSO

    assert_redirected_to all_servers_path
  end

  # The loop. Ops::SsoController defined `refuse(message)`, which overrode
  # Authorization#refuse(capability) — so a refusal redirected to the very page
  # that had just refused. A refusal must never name the path it refused.
  test "a refusal on the sign-in screen does not send you back to it" do
    sign_in_as(email: users(:contractor).email)

    get SSO

    assert_response :redirect
    assert_not_includes response.headers["Location"].to_s, SSO
  end

  # And the same for a refused WRITE, which is the path that still uses the
  # renamed helper.
  test "a refused write on the sign-in screen does not send you back to it" do
    sign_in_as(email: users(:contractor).email)

    post SSO, params: {owner_email: "someone@example.com"}

    assert_response :redirect
    assert_not_includes response.headers["Location"].to_s, SSO
    assert_equal 0, Ops::SsoConfig.count
  end

  # Someone with no membership at all is the base case, and nil must read as a
  # denial rather than as an unset value that falls through.
  test "no membership anywhere is a denial" do
    sign_in_as(email: "stranger@nowhere.example")

    get LICENSE

    assert_redirected_to all_servers_path
  end

  # The menu link and the endpoint must answer the same question. When they
  # disagree the menu either hides a page you can open or offers one you cannot.
  test "the account menu offers the ops links to an owner" do
    sign_in_as(email: users(:owner).email)

    get server_root_path(org_id: "acmeorg1", server_key: servers(:alpha).key)

    assert_select "a[href=?]", LICENSE
    assert_select "a[href=?]", SSO
  end

  test "the account menu withholds them from a member" do
    sign_in_as(email: users(:contractor).email)

    get server_root_path(org_id: "acmeorg1", server_key: servers(:alpha).key)

    assert_select "a[href=?]", LICENSE, false
    assert_select "a[href=?]", SSO, false
  end

  # The escalation the old shape allowed: role came from the org named in the
  # URL, so anyone appending ?org_id= for an org they owned satisfied the check.
  # The URL must no longer be able to answer this question at all.
  test "naming an org in the URL cannot elevate a member" do
    sign_in_as(email: users(:contractor).email)

    get "#{LICENSE}?org_id=acmeorg1"

    assert_redirected_to all_servers_path
  end

  test "naming someone else's org in the URL cannot elevate anyone" do
    sign_in_as(email: users(:contractor).email)

    get "#{SSO}?org_id=globex22"

    assert_response :redirect
    assert_not_includes response.headers["Location"].to_s, SSO
  end

  # The sidebar on the org-less screens. It used to render nothing at all there:
  # both groups needed a server to point at, and /ops/* has none selected — so
  # the two entries that live in the container itself disappeared on the very
  # screens they name.
  test "the sidebar carries the installation group where there is no server" do
    sign_in_as(email: users(:owner).email)

    get LICENSE

    assert_select "nav[aria-label=?]", "Primary"
    assert_select "a[href=?]", LICENSE
    assert_select "a[href=?]", SSO
  end

  # The item must light up on its own page. nav_active? built the comparison
  # path with org_id/server_key, which a route taking neither appends as a query
  # string — so "/ops/license" was compared against "/ops/license?org_id=…" and
  # never matched.
  test "the licence item is marked current on the licence page" do
    sign_in_as(email: users(:owner).email)

    get LICENSE

    assert_select "a[href=?][aria-current=?]", LICENSE, "page"
    assert_select "a[href=?][aria-current=?]", SSO, "page", false
  end

  test "the sign-in item is marked current on the sign-in page" do
    sign_in_as(email: users(:owner).email)

    get SSO

    assert_select "a[href=?][aria-current=?]", SSO, "page"
    assert_select "a[href=?][aria-current=?]", LICENSE, "page", false
  end

  # A group whose every item is refused must not leave its heading behind.
  test "a member sees no installation group at all" do
    sign_in_as(email: users(:contractor).email)

    get server_root_path(org_id: "acmeorg1", server_key: servers(:alpha).key)

    assert_select "a[href=?]", LICENSE, false
    assert_select "*", text: "Installation", count: 0
  end
end
