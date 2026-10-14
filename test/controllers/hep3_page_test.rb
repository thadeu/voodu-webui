# frozen_string_literal: true

require "test_helper"

# /hep3 — the calls of one voodu-hep3 reader. Pins: the page and its sidebar
# item exist only with the plugin installed, no reader in the URL shows the
# picker (no table fetch), a running reader renders the Calls DataTable with
# the page's window, and a reader that does not run falls back to the picker.
class Hep3PageTest < ActionDispatch::IntegrationTest
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @key = @server.key
  end

  def install_hep3
    System.create!(
      server: @server,
      payload: {host: {}, plugins: [{"name" => "hep3", "aliases" => ["hep"]}]}.to_json,
      synced_at: Time.current
    )
  end

  def run_reader(scope:, name:, replica: 1)
    Pod.create!(
      server: @server, container_name: "#{scope}-#{name}.#{replica}", kind: "deployment",
      scope: scope, resource_name: name, replica_id: replica.to_s, synced_at: Time.current,
      payload: {"name" => "#{scope}-#{name}.#{replica}", "scope" => scope, "resource_name" => name,
                "image" => "voodu-hep3-api:local", "running" => true}.to_json
    )
  end

  test "without the plugin the page refuses and the sidebar hides the item" do
    get hep3_path(server_key: @key)

    assert_redirected_to server_root_path(server_key: @key)
    assert_match "HEP3 is not installed", flash[:alert]

    get pods_path(server_key: @key)

    assert_no_match %r{href="[^"]*/hep3"}, @response.body
  end

  test "with the plugin the sidebar shows the item" do
    install_hep3

    get pods_path(server_key: @key)

    assert_match %r{href="[^"]*/#{@key}/hep3"}, @response.body
  end

  test "no reader chosen shows the picker, one card per reader deployment" do
    install_hep3
    run_reader(scope: "fsw", name: "hep3-api", replica: 1)
    run_reader(scope: "fsw", name: "hep3-api", replica: 2)
    run_reader(scope: "sbc", name: "hep3-api")

    get hep3_path(server_key: @key, range: "24h")

    assert_response :success
    assert_match "Which reader do you want to see?", @response.body
    assert_match "2 replicas", @response.body
    assert_match 'value="fsw:hep3-api"', @response.body
    assert_match 'value="sbc:hep3-api"', @response.body
    assert_match '<input type="hidden" name="range" value="24h">', @response.body, "picking a reader keeps the window"
    assert_match 'name="q"', @response.body, "the filter is set in the picker"
    assert_no_match 'data-controller="data-table"', @response.body
  end

  test "a chosen reader renders the Calls table with the page window and the call-flow host" do
    install_hep3
    run_reader(scope: "fsw", name: "hep3-api")

    get hep3_path(server_key: @key, scope: "fsw", name: "hep3-api", range: "6h", ws: "abcd1234")

    assert_response :success
    assert_match 'data-controller="data-table"', @response.body
    assert_match 'data-data-table-view-value="calls"', @response.body
    assert_match 'data-data-table-range-value="6h"', @response.body
    assert_match 'data-data-table-row-action-event-value="callflow"', @response.body
    assert_match 'data-data-table-key-value="hep3-page:abcd1234:fsw:hep3-api"', @response.body
    assert_match 'data-controller="hep3-call-flow"', @response.body
  end

  test "a reader that does not run falls back to the picker" do
    install_hep3
    run_reader(scope: "fsw", name: "hep3-api")

    get hep3_path(server_key: @key, scope: "fsw", name: "nope")

    assert_response :success
    assert_match "Which reader do you want to see?", @response.body
    assert_no_match 'data-controller="data-table"', @response.body
  end

  test "an unknown range falls back to the default preset" do
    install_hep3
    run_reader(scope: "fsw", name: "hep3-api")

    get hep3_path(server_key: @key, scope: "fsw", name: "hep3-api", range: "bogus")

    assert_match 'data-data-table-range-value="1h"', @response.body
  end

  test "plugin installed but no reader running explains what to deploy" do
    install_hep3

    get hep3_path(server_key: @key)

    assert_response :success
    assert_match "No HEP3 reader is running on this server", @response.body
  end

  test "the page sits in a workspace tab: a valid tab id is kept, the reader names the tab" do
    install_hep3
    run_reader(scope: "fsw", name: "hep3-api")

    get hep3_path(server_key: @key, scope: "fsw", name: "hep3-api", ws: "abcd1234")

    assert_match 'data-controller="workspace-tabs"', @response.body
    assert_match 'data-workspace-tabs-tab-id-value="abcd1234"', @response.body
    assert_match 'data-workspace-tabs-label-value="fsw · hep3-api"', @response.body
    assert_match %(data-workspace-tabs-storage-key-value="voodu:hep3-tabs:#{@key}"), @response.body
    assert_match '<input type="hidden" name="ws" value="abcd1234">', @response.body, "a range change stays in this tab"
  end

  test "a missing or malformed tab id gets a fresh one, the picker is a New tab" do
    install_hep3
    run_reader(scope: "fsw", name: "hep3-api")

    get hep3_path(server_key: @key, ws: "../evil")

    assert_match(/data-workspace-tabs-tab-id-value="[a-z0-9]{8}"/, @response.body)
    assert_no_match "../evil", @response.body
    assert_match 'data-workspace-tabs-label-value="New tab"', @response.body
    assert_match(/<input type="hidden" name="ws" value="[a-z0-9]{8}">/, @response.body, "picking a reader stays in this tab")
  end

  test "the filter comes from the URL: it feeds the table and shows in the subtitle" do
    install_hep3
    run_reader(scope: "fsw", name: "hep3-api")

    get hep3_path(server_key: @key, scope: "fsw", name: "hep3-api", ws: "abcd1234", q: "@to_user like /5511/")

    assert_match 'value="@to_user like /5511/"', @response.body
    assert_match 'title="@to_user like /5511/"', @response.body, "the active filter chip"
    assert_match "q=%40to_user", @response.body, "Change reader keeps the filter to edit it"
  end

  test "the picker's reader=scope:name redirects to the scope/name URL, keeping tab, window and filter" do
    install_hep3

    get hep3_path(server_key: @key, reader: "fsw:hep3-api", ws: "abcd1234", range: "6h", q: "@to_user like /55/")

    assert_redirected_to hep3_path(server_key: @key, range: "6h", ws: "abcd1234", q: "@to_user like /55/", scope: "fsw", name: "hep3-api")

    get hep3_path(server_key: @key, reader: "fsw:hep3-api", ws: "abcd1234", q: "")

    assert_redirected_to hep3_path(server_key: @key, ws: "abcd1234", scope: "fsw", name: "hep3-api")
  end

  test "a visit with no tab is fresh: hidden until the browser picks the first open tab" do
    install_hep3
    run_reader(scope: "fsw", name: "hep3-api")

    get hep3_path(server_key: @key)

    assert_match 'data-workspace-tabs-fresh-value="true"', @response.body
    assert_match(/class="[^"]*invisible[^"]*" data-workspace-tabs-target="content"/, @response.body)

    get hep3_path(server_key: @key, ws: "abcd1234")

    assert_match 'data-workspace-tabs-fresh-value="false"', @response.body
    assert_no_match(/invisible[^"]*" data-workspace-tabs-target="content"/, @response.body)
  end

  def capture(call_id, at)
    payload = {ts: at.utc.strftime("%Y-%m-%d %H:%M:%S.000000"), call_id: call_id, x_cid: "", method: "INVITE",
               response_code: 0, from_user: "alice", to_user: "bob"}.to_json

    HepMessage.bulk_insert([{server_id: @server.id, scope: "fsw", name: "hep3-api", payload: payload}])
  end

  test "a chosen reader renders the Metrics-style grid: count card, table, settings, query editor" do
    install_hep3
    run_reader(scope: "fsw", name: "hep3-api")

    get hep3_path(server_key: @key, scope: "fsw", name: "hep3-api", ws: "abcd1234")

    assert_match 'data-metrics-display-kind-value="hep3"', @response.body
    assert_match 'data-metric-key="calls_count"', @response.body
    assert_match 'data-metric-key="calls_table"', @response.body
    assert_match 'id="hep3-count"', @response.body
    assert_match "/hep3/count?", @response.body, "the count frame polls its own endpoint"
    assert_match "/hep3/display_settings", @response.body
    assert_no_match 'data-controller="query-editor"', @response.body, "the filter is edited in the picker, not over the panels"
    assert_match "filter — e.g.", @response.body, "the table keeps its own filter input"
  end

  test "count answers the distinct calls in the window, filtered by q" do
    install_hep3
    run_reader(scope: "fsw", name: "hep3-api")

    now = Time.current
    capture("call-1", now - 5.minutes)
    capture("call-1", now - 4.minutes)
    capture("call-2", now - 3.minutes)
    capture("old-call", now - 3.hours)

    get hep3_count_path(server_key: @key, scope: "fsw", name: "hep3-api", range: "1h", ws: "abcd1234")

    assert_response :success
    assert_match 'id="hep3-count"', @response.body
    assert_match(/>2</, @response.body, "call-1 counts once, old-call is outside the window")
    assert_no_match(/<html/, @response.body)

    get hep3_count_path(server_key: @key, scope: "fsw", name: "hep3-api", range: "1h", q: "@call_id like /call-2/")

    assert_match(/>1</, @response.body)
  end

  test "count and settings refuse without the plugin" do
    get hep3_count_path(server_key: @key, scope: "fsw", name: "hep3-api")

    assert_redirected_to server_root_path(server_key: @key)

    get hep3_display_settings_path(server_key: @key)

    assert_redirected_to server_root_path(server_key: @key)
  end

  test "the settings drawer lists the two panels" do
    install_hep3

    get hep3_display_settings_path(server_key: @key)

    assert_response :success
    assert_match 'data-metrics-display-settings-kind-value="hep3"', @response.body
    assert_match 'data-metric="calls_count"', @response.body
    assert_match 'data-metric="calls_table"', @response.body
  end
end
