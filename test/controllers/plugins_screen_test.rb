# frozen_string_literal: true

require "test_helper"

# The plugins screen for one server.
#
# Everything here is the box's answer, not ours — nothing about plugins is
# persisted, so these tests stub the controller's HTTP surface rather than
# setting up records. What they pin is the part that is ours: that an
# unreachable server is not reported as "no plugins", that an install in flight
# reaches the operator, and that installing is gated harder than reading.
class PluginsScreenTest < ActionDispatch::IntegrationTest
  ORG = "acmeorg1"

  setup do
    @server = servers(:alpha)
    sign_in_as(email: users(:owner).email)
    Rails.cache.clear
  end

  def page = get(plugins_path(org_id: ORG, server_key: @server.key))

  def stub_plugins(plugins, status: 200)
    stub_request(:get, %r{/api/pat/v1/plugins\z}).to_return(
      status: status,
      body: {status: "ok", data: {plugins: plugins, errors: []}}.to_json,
      headers: {"Content-Type" => "application/json"}
    )
  end

  def installed(name:, version: "1.0.0", description: "does a thing", homepage: "https://github.com/o/#{name}")
    {"name" => name, "version" => version, "description" => description,
     "homepage" => homepage, "state" => "installed"}
  end

  test "the screen lists what is installed on the server" do
    stub_plugins([installed(name: "voodu-redis", version: "0.3.1")])

    page

    assert_response :success
    assert_select "h3", text: "voodu-redis"
    assert_includes response.body, "v0.3.1"
    assert_select "a[href=?]", "https://github.com/o/voodu-redis"
  end

  # The card is where an async install reports back, so it has to appear the
  # moment the install starts — not when it finishes.
  test "an install still running shows as installing" do
    stub_plugins([{"name" => "voodu-postgres", "state" => "installing", "source" => "o/voodu-postgres"}])

    page

    assert_select "h3", text: "voodu-postgres"
    assert_includes response.body, "installing"
  end

  # The card must not change shape mid-operation: the button stays a button and
  # only its label moves. Swapping it for a sentence is a flinch exactly when
  # the operator is watching to see whether their click landed.
  test "an update in flight relabels the button instead of removing it" do
    stub_plugins([{"name" => "traffik", "version" => "0.1.1", "state" => "installing",
                   "source" => "thadeu/voodu-traffik"}])

    page

    assert_select "article button[disabled]", 1
    assert_includes response.body, "Updating…"
    assert_not_includes response.body, "this card updates on its own"
  end

  # A first install has no version to update from, so it says so.
  test "a first install says installing, not updating" do
    stub_plugins([{"name" => "voodu-postgres", "state" => "installing",
                   "source" => "thadeu/voodu-postgres"}])

    page

    assert_includes response.body, "Installing…"
    assert_not_includes response.body, "Updating…"
  end

  # And a failure has to say why, or the operator ends up on the box anyway —
  # which is the thing this screen exists to prevent.
  test "a failed install shows the reason the controller gave" do
    stub_plugins([{"name" => "voodu-nope", "state" => "failed",
                   "source" => "o/voodu-nope", "error" => "git clone failed: repository not found"}])

    page

    assert_includes response.body, "repository not found"
  end

  # The regression worth guarding: an unreachable box is not an empty list.
  test "an unreachable server is not reported as having no plugins" do
    stub_request(:get, %r{/api/pat/v1/plugins\z}).to_timeout

    page

    assert_response :success
    assert_includes response.body, "Could not reach this server"
    assert_not_includes response.body, "No plugins on this server yet"
  end

  # Found by pointing this at a real box still on the previous release: a 404
  # is not an outage. The fix is a controller version, not the network, and the
  # two messages send the operator to different places.
  test "an older controller is named as such, not reported as unreachable" do
    stub_request(:get, %r{/api/pat/v1/plugins\z}).to_return(
      status: 404, body: {status: "error", error: "not found"}.to_json,
      headers: {"Content-Type" => "application/json"}
    )

    page

    assert_response :success
    assert_includes response.body, "older controller"
    assert_not_includes response.body, "Could not reach this server"
  end

  test "a transport failure is still reported as unreachable" do
    stub_request(:get, %r{/api/pat/v1/plugins\z}).to_timeout

    page

    assert_includes response.body, "Could not reach this server"
    assert_not_includes response.body, "older controller"
  end

  # A server with nothing installed is not an empty page any more — it is the
  # catalogue, which is the whole reason discovery was added. The count says
  # zero; the cards say what could be there.
  test "an empty server shows the catalogue rather than an empty state" do
    stub_plugins([])

    page

    assert_select "article h3", PluginCatalogue.all.size
    assert_includes response.body, "0"
    assert_not_includes response.body, "Nothing to show"
  end

  # REVERSED on 2026-09-01. This used to read "a member can read the screen",
  # on the reasoning that installing (which clones a repository and runs its
  # hooks on the operator's machine) is a different bracket from reading a
  # list. True, and it left a member with a marketplace they could browse and
  # not use — every control on it refusing them.
  #
  # The sidebar item is hidden for members now, and a hidden door that still
  # opens by typing the URL is the same inconsistency in the other direction.
  # So the screen goes with it: reading the list is not a feature on its own.
  test "a member is refused the screen entirely, not just its controls" do
    stub_plugins([installed(name: "voodu-redis")])
    sign_in_as(email: users(:contractor).email)

    page

    assert_response :redirect
    assert_match(/admin/i, flash[:alert].to_s)
  end

  test "and the sidebar does not offer them the door" do
    stub_plugins([installed(name: "voodu-redis")])
    sign_in_as(email: users(:contractor).email)

    get server_root_path(org_id: "acmeorg1", server_key: servers(:alpha).key)

    assert_response :success
    assert_select "nav a[href*=?]", "/plugins", count: 0
  end

  test "a member cannot install even by posting directly" do
    sign_in_as(email: users(:contractor).email)

    post plugins_path(org_id: ORG, server_key: @server.key), params: {source: "o/thing"}

    assert_redirected_to all_servers_path
  end

  test "a member cannot uninstall either" do
    sign_in_as(email: users(:contractor).email)

    delete plugin_path(org_id: ORG, server_key: @server.key, name: "voodu-redis")

    assert_redirected_to all_servers_path
  end

  test "installing asks the controller and returns without waiting" do
    request = stub_request(:post, %r{/api/pat/v1/plugins/install\z}).to_return(
      status: 202, body: {status: "ok", data: {source: "o/thing", state: "installing"}}.to_json,
      headers: {"Content-Type" => "application/json"}
    )

    post plugins_path(org_id: ORG, server_key: @server.key), params: {source: "o/thing"}

    assert_requested request
    assert_redirected_to plugins_path(org_id: ORG, server_key: @server.key)
  end

  test "an empty source is refused before it reaches the server" do
    post plugins_path(org_id: ORG, server_key: @server.key), params: {source: "   "}

    assert_not_requested :post, %r{/api/pat/v1/plugins/install}
    assert_match(/Enter a plugin/, flash[:alert])
  end

  test "uninstalling asks the controller" do
    request = stub_request(:delete, %r{/api/pat/v1/plugins/voodu-redis\z}).to_return(
      status: 200, body: {status: "ok", data: {name: "voodu-redis"}}.to_json,
      headers: {"Content-Type" => "application/json"}
    )

    delete plugin_path(org_id: ORG, server_key: @server.key, name: "voodu-redis")

    assert_requested request
  end

  # config/environments/test.rb pins :null_store, which is right for the suite
  # as a whole — a test that caches is a test that leaks into the next one. The
  # two below are about the caching itself, so they need somewhere real to put
  # it, and put the null store back on the way out.
  def with_a_real_cache
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    yield
  ensure
    Rails.cache = previous
  end

  # The point of the cache: a refresh must not cross the network again.
  test "a second render inside the TTL does not hit the server twice" do
    with_a_real_cache do
      request = stub_plugins([installed(name: "voodu-redis")])

      page
      page

      assert_requested request, times: 1
    end
  end

  # And the operator's own change must not leave them looking at a stale card.
  test "installing expires the cache so the next render is fresh" do
    with_a_real_cache do
      list = stub_plugins([installed(name: "voodu-redis")])
      stub_request(:post, %r{/api/pat/v1/plugins/install\z}).to_return(
        status: 202, body: {status: "ok"}.to_json, headers: {"Content-Type" => "application/json"}
      )

      page
      post plugins_path(org_id: ORG, server_key: @server.key), params: {source: "o/thing"}
      page

      assert_requested list, times: 2
    end
  end

  # ── Pagination ────────────────────────────────────────────────────

  def many_plugins(count)
    (1..count).map { |i| installed(name: format("plugin-%02d", i)) }
  end

  test "a single page shows no pagination at all" do
    stub_plugins([])

    page

    assert_select "nav[aria-label=?]", "Pagination", false
  end

  test "more than a page paginates, above and below" do
    stub_plugins(many_plugins(30))

    page

    assert_select "nav[aria-label=?]", "Pagination", 2
  end

  test "the first page holds twenty-five and stops there" do
    stub_plugins(many_plugins(30))

    page

    assert_select "article h3", 25
    assert_select "h3", text: "plugin-01"
    assert_select "h3", text: "plugin-26", count: 0
  end

  # 30 installed + the catalogue's entries, none of which this server has.
  test "the second page holds the remainder, installed and available together" do
    stub_plugins(many_plugins(30))

    get plugins_path(org_id: ORG, server_key: @server.key, page: 2)

    assert_select "article h3", 5 + PluginCatalogue.all.size
    assert_select "h3", text: "plugin-26"
    assert_select "h3", text: "plugin-01", count: 0
  end

  # A bookmarked page that no longer exists lands on the last real one rather
  # than on an empty grid that looks like the server lost its plugins.
  test "a page past the end clamps to the last one" do
    stub_plugins(many_plugins(30))

    get plugins_path(org_id: ORG, server_key: @server.key, page: 99)

    assert_select "article h3", 5 + PluginCatalogue.all.size
    assert_select "h3", text: "plugin-26"
  end

  # The bug this guards: the grid refetches every five seconds, and a src
  # without the page would drag whoever is on page two back to page one — long
  # enough after their click to read as the page misbehaving.
  test "the polling frame refetches the page the operator is on" do
    stub_plugins(many_plugins(30))

    get plugins_path(org_id: ORG, server_key: @server.key, page: 2)

    assert_select "turbo-frame[id=?][src=?]", "plugins-grid",
      plugins_path(org_id: ORG, server_key: @server.key, page: 2)
  end

  # Every card is the same height, which only holds because the description is
  # bounded — manifest descriptions run from one line to seven.
  test "the description is a fixed band so the cards line up" do
    stub_plugins([installed(name: "wordy", description: "x " * 400)])

    page

    assert_select "p[class*=?]", "min-h-[84px]"
    assert_select "p[class*=?]", "max-h-[84px]"
  end

  # ── Sort ──────────────────────────────────────────────────────────

  test "the default order is by name, ascending" do
    stub_plugins([installed(name: "zebra"), installed(name: "alpha")])

    page

    names = css_select("article h3").map { |n| n.text.strip }

    assert_equal %w[alpha zebra], names.first(2)
  end

  test "descending reverses it" do
    stub_plugins([installed(name: "zebra"), installed(name: "alpha")])

    get plugins_path(org_id: ORG, server_key: @server.key, sort: "name_desc")

    names = css_select("article h3").map { |n| n.text.strip }

    assert_equal %w[zebra alpha], names.first(2)
  end

  # A sort nobody offered falls back — and, more to the point, is not echoed
  # back into the page. The order alone could not tell the two apart, since
  # garbage sorts ascending like the default does.
  test "an unknown sort falls back and is not reflected back" do
    stub_plugins([installed(name: "zebra"), installed(name: "alpha")])

    get plugins_path(org_id: ORG, server_key: @server.key, sort: "name; drop table")

    names = css_select("article h3").map { |n| n.text.strip }

    assert_equal %w[alpha zebra], names.first(2)
    assert_not_includes response.body, "drop table"
    assert_select "select#plugins-sort option[selected]", 1
  end

  # Same reason the page is carried: a tick that dropped the sort would
  # silently reorder the grid five seconds after the operator set it.
  test "the polling frame keeps the sort" do
    stub_plugins([installed(name: "a")])

    get plugins_path(org_id: ORG, server_key: @server.key, sort: "name_desc")

    assert_select "turbo-frame[src=?]",
      plugins_path(org_id: ORG, server_key: @server.key, sort: "name_desc")
  end

  # ── The catalogue ─────────────────────────────────────────────────

  # Without this the screen is an inventory, not a marketplace: an operator
  # with nothing installed sees an empty page and no way to learn what exists.
  test "plugins this server does not have are offered" do
    stub_plugins([])

    page

    assert_select "h3", text: "voodu-postgres"
    assert_select "h3", text: "voodu-redis"
    assert_includes response.body, "not installed"
  end

  # And once it HAS one, the catalogue must stop offering it.
  test "an installed plugin is not offered again" do
    stub_plugins([installed(name: "redis", homepage: "https://github.com/thadeu/voodu-redis")])

    page

    assert_select "h3", text: "redis", count: 1
  end

  # The mismatch that caused a duplicate card on the controller: the repository
  # is voodu-traffik and the plugin inside it is traffik. Matching on either
  # alone would offer an install for something already installed.
  test "a plugin whose repo is named differently is still recognised" do
    stub_plugins([installed(name: "traffik", homepage: "https://github.com/thadeu/voodu-traffik")])

    page

    assert_select "h3", text: "traffik", count: 1

    # The card that must NOT appear. Counting "traffik" cards could never see
    # this: the duplicate arrives under the repository's name, so the count of
    # the plugin's name stays at one either way.
    #
    # Asserted on the heading, not on a hidden source input — the installed
    # card's own Update form carries that repository too, quite correctly.
    assert_select "h3", text: "voodu-traffik", count: 0
  end

  # Deduplication is by REPOSITORY, not by name — and a plugin installed from a
  # directory on the box, with no homepage, is deliberately not matched. Some-
  # thing called "redis" on disk is not necessarily thadeu/voodu-redis, and
  # assuming it is would hide the real one from the catalogue.
  test "a locally installed plugin does not suppress the catalogue entry" do
    stub_plugins([{"name" => "redis", "version" => "0.1.0", "state" => "installed", "homepage" => ""}])

    page

    assert_select "h3", text: "redis", count: 1
    assert_select "h3", text: "voodu-redis", count: 1
  end

  # The duplicate on the INSTALL side, which is the same mismatch as the update
  # one wearing different clothes: the in-flight row is named for the
  # repository ("voodu-hep3") and carries the repo only in `source`, while the
  # catalogue entry is named for the plugin ("hep3"). Looking at neither meant
  # the catalogue kept offering an install for something already installing.
  test "a catalogue plugin being installed is not offered again" do
    stub_plugins([{"name" => "voodu-hep3", "state" => "installing",
                   "source" => "thadeu/voodu-hep3", "homepage" => ""}])

    page

    assert_select "h3", text: "voodu-hep3", count: 1

    # Precisely: no install form targets this repository. The other catalogue
    # cards keep their own Install buttons, so counting buttons would only have
    # counted those.
    assert_select "input[name=source][value=?]", "thadeu/voodu-hep3", count: 0
  end

  # A card is named for its repository, in every state. Translating between
  # "voodu-hep3" and the plugin name inside it ("hep3") was a table to keep in
  # sync; showing what we were given means the same repository always produces
  # the same card.
  test "a card is named for its repository, before and during an install" do
    stub_plugins([{"name" => "voodu-hep3", "state" => "installing",
                   "source" => "thadeu/voodu-hep3", "homepage" => ""}])

    page

    assert_select "h3", text: "voodu-hep3"
  end

  # Offering an install against a box we could not reach would be inviting a
  # click that cannot work.
  test "an unreachable server is not offered a catalogue" do
    stub_request(:get, %r{/api/pat/v1/plugins\z}).to_timeout

    page

    assert_select "h3", text: "postgres", count: 0
  end

  test "installing from a catalogue card sends the repository" do
    request = stub_request(:post, %r{/api/pat/v1/plugins/install\z})
      .with(body: hash_including("source" => "thadeu/voodu-mongodb"))
      .to_return(status: 202, body: {status: "ok"}.to_json,
        headers: {"Content-Type" => "application/json"})

    post plugins_path(org_id: ORG, server_key: @server.key), params: {source: "thadeu/voodu-mongodb"}

    assert_requested request
  end
end
