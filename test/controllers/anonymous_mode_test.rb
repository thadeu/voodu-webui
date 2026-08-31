# frozen_string_literal: true

require "test_helper"

# Anonymous mode — the self-hosted shape, and the default one.
#
# With CLOWK_ENABLED off the app asks for no credentials: the perimeter
# (Twingate, a VPN, Cloudflare Access) is the door, and whoever reaches the port
# has already proved who they are to it. What matters here is that skipping
# sign-in did NOT buy a second way to reach a server.
#
# So the sharp test is not "the page renders". It is that the fixture orgs — the
# ones a signed-in operator reaches through a membership — stay invisible, and
# that a bare server key still 404s. If those ever start working, anonymous mode
# has stopped being one identity and started being a bypass.
class AnonymousModeTest < ActionDispatch::IntegrationTest
  setup do
    sign_out
    @previous = Rails.application.config.x.clowk_enabled
    Rails.application.config.x.clowk_enabled = false
  end

  teardown { Rails.application.config.x.clowk_enabled = @previous }

  test "the app serves without any credential" do
    get root_path

    assert_response :redirect
    assert_no_match(/sign_in|login/, response.location.to_s)
  end

  test "the operator owns exactly one org, and it is not a fixture org" do
    get root_path

    operator = User.find_by!(email: User::LOCAL_OPERATOR_EMAIL)

    assert_equal 1, operator.active_orgs.count
    assert_equal :owner, operator.membership_in(operator.active_orgs.sole).role.to_sym
    assert_not_includes operator.active_orgs.map(&:name), orgs(:acme).name
  end

  # The whole point. Resolving an identity without sign-in must not widen what
  # that identity reaches — membership is still the only source of access.
  test "another org's server stays unreachable" do
    alpha = servers(:alpha)

    get server_root_path(org_id: orgs(:acme).short_id, server_key: alpha.key)

    assert_not_equal 200, response.status
    assert_not_includes response.body.to_s, alpha.endpoint
  end

  test "the server registry lists what the operator owns, and nothing else" do
    org = User.local_operator.active_orgs.sole
    mine = org.servers.create!(name: "mine-here", endpoint: "http://10.5.5.5:8687", pat: "x")

    get servers_path(org_id: org.short_id)

    assert_response :success
    # The positive half matters: without it this passes just as well when the
    # page lists no servers at all, for any reason.
    assert_includes response.body, mine.name
    assert_not_includes response.body, servers(:alpha).name
    assert_not_includes response.body, servers(:gamma).name
  end

  # Two Puma workers can take a first request at the same instant. The unique
  # index on email is the serialisation point; the workspace is built in the
  # same transaction, so a loser leaves nothing behind.
  test "concurrent resolution provisions one operator, not two" do
    threads = 4.times.map { Thread.new { User.local_operator } }
    threads.each(&:join)

    assert_equal 1, User.where(email: User::LOCAL_OPERATOR_EMAIL).count
    assert_equal 1, Account.where(owner: User.find_by!(email: User::LOCAL_OPERATOR_EMAIL)).count
  end

  # A leftover cookie from a previous Clowk deployment must not resurrect an
  # identity the operator did not ask for.
  test "a stale Clowk session does not override the local operator" do
    cookies[Clowk.config.cookie_key] = ClowkDevToken.mint(
      sub: "stale", email: "someone@example.com", name: "Stale", email_verified: true
    )

    get root_path
    follow_redirect! while response.redirect?

    assert_equal User::LOCAL_OPERATOR_EMAIL, User.find_by!(email: User::LOCAL_OPERATOR_EMAIL).email
    assert_not_includes response.body.to_s, "someone@example.com"
  end

  # ── The surfaces that only mean something with per-person identity ─────

  test "Members and Sign out are not offered" do
    org = User.local_operator.active_orgs.sole
    server = org.servers.create!(name: "s1", endpoint: "http://10.5.5.6:8687", pat: "x")

    get server_root_path(org_id: org.short_id, server_key: server.key)

    assert_response :success
    assert_not_includes response.body, "Sign out"
    assert_not_includes response.body, org_members_path(org_id: org.short_id)
  end

  # The workspace already exists, so the screen for "you belong nowhere" must
  # never be where an anonymous operator lands.
  test "onboarding is not where the operator arrives" do
    get root_path

    assert_response :redirect
    assert_not_includes response.location.to_s, "onboarding"

    get new_onboarding_path

    assert_response :redirect
    assert_not_includes response.location.to_s, "onboarding"
  end

  # ── The perimeter warning ─────────────────────────────────────────────

  # Addressed at a rendered page rather than through root_path: follow_redirect!
  # drops custom headers, so the REMOTE_ADDR under test would not survive the
  # hop and every one of these would pass for the wrong reason.
  def a_rendered_page
    new_server_path(org_id: User.local_operator.active_orgs.sole.short_id)
  end

  test "a request from a public address is warned about" do
    get a_rendered_page, headers: {"REMOTE_ADDR" => "54.20.48.217"}

    assert_response :success
    assert_includes response.body, "No sign-in required"
    assert_includes response.body, "VOODU_TRUSTED_PERIMETER=1"
  end

  test "a request from inside the network is not warned about" do
    get a_rendered_page, headers: {"REMOTE_ADDR" => "10.0.0.4"}

    assert_response :success
    assert_not_includes response.body, "No sign-in required"
  end

  test "the warning can be silenced by declaring the perimeter trusted" do
    original = ENV["VOODU_TRUSTED_PERIMETER"]
    ENV["VOODU_TRUSTED_PERIMETER"] = "1"

    get a_rendered_page, headers: {"REMOTE_ADDR" => "54.20.48.217"}

    assert_response :success
    assert_not_includes response.body, "No sign-in required"
  ensure
    ENV["VOODU_TRUSTED_PERIMETER"] = original
  end

  # If the workspace is destroyed out from under the operator, the next request
  # rebuilds it rather than parking them on an onboarding screen this mode does
  # not show.
  test "a destroyed workspace is rebuilt on the next request" do
    operator = User.local_operator
    operator.active_orgs.each { |org| org.destroy! }
    operator.owned_accounts.each { |account| account.reload.destroy! }

    assert_equal 1, User.local_operator.active_orgs.count
  end

  # The upgrade path this product is sold on: run the free tier, buy a licence,
  # paste it in. It was impossible — /ops/license carries no :org_id, so the
  # capability table had no org to answer about and refused the one operator
  # this installation has.
  #
  # Drops the test-only global default_url_options[:org_id]: a real /ops/*
  # request has no org in its path, and with the global left in place these
  # rendered while the browser got a 500.
  test "the anonymous operator can open the licence screen they paid for" do
    pinned = Rails.application.routes.default_url_options.delete(:org_id)

    get "/ops/license"

    assert_response :success
    assert_select "form[action=?]", "/ops/license"
  ensure
    Rails.application.routes.default_url_options[:org_id] = pinned if pinned
  end

  test "the anonymous operator can open the sign-in screen to upgrade" do
    pinned = Rails.application.routes.default_url_options.delete(:org_id)

    get "/ops/sso"

    assert_response :success
    assert_select "form[action=?]", "/ops/sso"
  ensure
    Rails.application.routes.default_url_options[:org_id] = pinned if pinned
  end

  # The account menu was hidden entirely in anonymous mode. It also carries the
  # License and SSO links, so hiding it left a free-tier operator with no way to
  # reach the licence they had just paid for.
  test "the account menu is shown in anonymous mode, with the same details" do
    pinned = Rails.application.routes.default_url_options.delete(:org_id)

    get "/ops/license"

    assert_select "summary[aria-label=?]", "Account"
    assert_includes response.body, User::LOCAL_OPERATOR_EMAIL
    assert_select "span", text: "owner"
    assert_select "span", text: "version"
  ensure
    Rails.application.routes.default_url_options[:org_id] = pinned if pinned
  end

  # What does NOT belong there: anonymous mode has no sign-in to end, and the
  # link would promise a way back in that does not exist.
  test "the account menu offers no way to sign out of anonymous mode" do
    pinned = Rails.application.routes.default_url_options.delete(:org_id)

    get "/ops/license"

    assert_response :success
    assert_select "a", text: "Sign out", count: 0
  ensure
    Rails.application.routes.default_url_options[:org_id] = pinned if pinned
  end

  # The address was renamed. An installation that ran an earlier build already
  # holds its whole workspace under the old one, so the row is adopted rather
  # than passed over — otherwise a second operator appears beside the first and
  # the servers, PATs and licence history end up behind a sign-in anonymous mode
  # never shows.
  test "an operator provisioned under the old address is adopted, not duplicated" do
    User.where(email: User::LOCAL_OPERATOR_EMAIL).destroy_all
    legacy = User.create!(email: User::LEGACY_LOCAL_OPERATOR_EMAILS.first,
      name: "Local operator", email_verified: false)
    Account.provision!(owner: legacy, account_name: "Local", org_name: "Default")
    before = User.count

    adopted = User.local_operator

    assert_equal legacy.id, adopted.id
    assert_equal User::LOCAL_OPERATOR_EMAIL, adopted.email
    assert_equal User::LOCAL_OPERATOR_NAME, adopted.name
    assert_equal before, User.count
    assert_not User.exists?(email: User::LEGACY_LOCAL_OPERATOR_EMAILS.first)
  end

  # And the workspace it carried comes with it — the point of adopting at all.
  test "the adopted operator keeps the org it already owned" do
    User.where(email: User::LOCAL_OPERATOR_EMAIL).destroy_all
    legacy = User.create!(email: User::LEGACY_LOCAL_OPERATOR_EMAILS.first,
      name: "Local operator", email_verified: false)
    Account.provision!(owner: legacy, account_name: "Local", org_name: "Default")
    org_ids = legacy.active_orgs.pluck(:id)

    assert_equal org_ids, User.local_operator.active_orgs.pluck(:id)
  end

  # The sidebar beside the installation screens drew only its two container-wide
  # icons: the server list is scoped to the org in the URL, and /ops/* names
  # none. Everything this operator may reach belongs there instead.
  test "the sidebar on an installation screen still reaches the servers" do
    pinned = Rails.application.routes.default_url_options.delete(:org_id)
    operator = User.local_operator
    org = operator.active_orgs.sole
    server = Server.create!(org: org, name: "box", endpoint: "http://box.example:8687",
      pat: "pat_" + ("a" * 28))

    get "/ops/license"

    assert_response :success
    assert_select "a[href=?]", server_root_path(org_id: org.short_id, server_key: server.key)
    assert_select "a[href=?]", pods_path(org_id: org.short_id, server_key: server.key)
  ensure
    Rails.application.routes.default_url_options[:org_id] = pinned if pinned
  end

  # An installation whose ADDRESS was already carried forward by a previous boot
  # still holds the old display name — so the name is corrected on its own, not
  # only as a passenger of the address change.
  test "the display name is carried forward even when the address already was" do
    User.where(email: User::LOCAL_OPERATOR_EMAIL).destroy_all
    current = User.create!(email: User::LOCAL_OPERATOR_EMAIL,
      name: User::LEGACY_LOCAL_OPERATOR_NAMES.first, email_verified: false)
    Account.provision!(owner: current, account_name: "Local", org_name: "Default")

    assert_equal User::LOCAL_OPERATOR_NAME, User.local_operator.name
    assert_equal current.id, User.local_operator.id
  end

  # A name set deliberately is not seed data, and must survive the correction.
  test "a name this code never seeded is left alone" do
    User.where(email: User::LOCAL_OPERATOR_EMAIL).destroy_all
    named = User.create!(email: User::LOCAL_OPERATOR_EMAIL, name: "Night shift", email_verified: false)
    Account.provision!(owner: named, account_name: "Local", org_name: "Default")

    assert_equal "Night shift", User.local_operator.name
  end

  test "the account menu shows the free-tier name" do
    pinned = Rails.application.routes.default_url_options.delete(:org_id)

    get "/ops/license"

    assert_includes response.body, User::LOCAL_OPERATOR_NAME
    assert_not_includes response.body, User::LEGACY_LOCAL_OPERATOR_NAMES.first
  ensure
    Rails.application.routes.default_url_options[:org_id] = pinned if pinned
  end

  # "none" is the self-hosted default, not a fault: the perimeter authenticates
  # and this app is deliberately not a second door. Saying so in the menu beats
  # leaving an operator to wonder whether sign-in is broken.
  test "the sign-in row says none when the perimeter is what authenticates" do
    pinned = Rails.application.routes.default_url_options.delete(:org_id)

    get "/ops/license"

    assert_select "a[href='/ops/sso'] span", text: "none"
    assert_select "a[href='/ops/sso'] span", text: "clowk", count: 0
  ensure
    Rails.application.routes.default_url_options[:org_id] = pinned if pinned
  end

  # The pitch that matters most on a free self-hosted box: it is the one screen
  # where an operator is looking at anonymous mode and might not know there is
  # an alternative.
  test "the anonymous installation is told sign-in can be bought" do
    pinned = Rails.application.routes.default_url_options.delete(:org_id)

    get "/ops/sso"

    assert_response :success
    assert_select "a[href=?]", "https://clowk.in"
    assert_select "a[rel~=?]", "noopener"
  ensure
    Rails.application.routes.default_url_options[:org_id] = pinned if pinned
  end

  # But not when the ENVIRONMENT decides sign-in: the form beside it is inert
  # there, and a purchase link would point at the wrong lever — the fix is an
  # env var on the host, which the card already says.
  test "an env-pinned installation is not sold sign-in" do
    pinned = Rails.application.routes.default_url_options.delete(:org_id)
    ENV["CLOWK_ENABLED"] = "0"

    get "/ops/sso"

    assert_select "a[href=?]", "https://clowk.in", false
  ensure
    ENV.delete("CLOWK_ENABLED")
    Rails.application.routes.default_url_options[:org_id] = pinned if pinned
  end
end
