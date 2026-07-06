# frozen_string_literal: true

require "test_helper"

# The ⌘K palette is a server-LESS endpoint, so route helpers there get no
# org_id from default_url_options — every href must name its server's org + key
# itself (CommandSet#loc). The feed is scoped to the org passed as ?org, since
# the endpoint can't infer it. These tests lock both in: the palette went empty
# once because it iterated the (now org-scoped, here nil) all_servers.
class CommandPaletteControllerTest < ActionDispatch::IntegrationTest
  fixtures :orgs, :servers

  setup do
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1" # read pods from the (empty) warehouse table, no network
  end

  teardown { ENV["WAREHOUSE"] = @prev_wh }

  def commands_for(**params)
    get command_palette_path, params: params
    assert_response :success

    JSON.parse(response.body).fetch("commands")
  end

  test "?org scopes the feed to that org's servers with fully-qualified hrefs" do
    commands = commands_for(org: "acmeorg1")

    # Way more than the 2 global actions — Navigate + saved queries per server.
    assert_operator commands.size, :>, 2

    nav = commands.select { |c| c["group"] == "Navigate" }
    assert nav.any?, "org-scoped feed must include per-server Navigate commands"

    # The regression: every per-server href must carry BOTH org_id + server_key.
    nav.each do |c|
      assert_match %r{\A/acmeorg1/(aaaaaa|bbbbbb)(/|\z)}, c["href"],
        "nav href must be org+server qualified, got #{c["href"].inspect}"
    end
  end

  test "no ?org yields only the global actions (org-less surfaces)" do
    commands = commands_for

    assert_equal ["Actions"], commands.map { |c| c["group"] }.uniq
    # Compare paths sans query — the test harness's global default_url_options
    # appends a stray ?org_id here that the real (path-param-based) one doesn't.
    paths = commands.map { |c| c["href"].split("?").first }.sort
    assert_equal ["/servers", "/servers/new"], paths
  end

  test "an unknown ?org falls back to globals only (no leak, no 500)" do
    commands = commands_for(org: "nope0000")

    assert_equal ["Actions"], commands.map { |c| c["group"] }.uniq
  end

  test "?current excludes the active server from the switch list" do
    commands = commands_for(org: "acmeorg1", current: "aaaaaa")

    switches = commands.select { |c| c["group"] == "Servers" }.map { |c| c["title"] }
    assert_includes switches, "Switch to beta"
    assert_not_includes switches, "Switch to alpha", "the current server is not offered as a switch target"
  end

  test "the feed never crosses into another org" do
    commands = commands_for(org: "acmeorg1")

    # gamma (globex) must never appear in acme's palette.
    assert_not commands.any? { |c| c["href"].to_s.include?("cccccc") || c["match"].to_s.include?("gamma") },
      "acme's palette must not surface another org's server"
  end
end
