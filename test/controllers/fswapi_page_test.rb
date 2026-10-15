# frozen_string_literal: true

require "test_helper"

# /fswapi — the FreeSWITCH page (voodu-fswapi plugin). Pins: the page and its
# "Plugins" sidebar group exist only with the plugin; the page shows the live
# status, the chosen list and the count cards; a FreeSWITCH that does not
# answer shows the plugin's own message (it names the fix).
class FswapiPageTest < ActionDispatch::IntegrationTest
  fixtures :orgs, :servers

  # FakeFswapi stands in for Voodu::Client: canned replies per route, or the
  # error the PAT proxy raises when FreeSWITCH is down.
  class FakeFswapi
    def initialize(replies: {}, error: nil)
      @replies = replies
      @error = error
    end

    def fswapi(route, _params = nil)
      raise @error if @error

      @replies.fetch(route)
    end
  end

  REPLIES = {
    "overview" => {"calls" => 1, "channels" => 2,
                   "status" => {"up" => true, "version" => "FreeSWITCH Version 1.10.11-release (64bit)",
                                "uptime_seconds" => 93_784, "idle_cpu" => 97.1, "sessions_peak" => 9, "sessions_max" => 1000}},
    "calls" => {"count" => 1, "rows" => [{"cid_num" => "5511999990000", "dest" => "4000",
                                          "callstate" => "ACTIVE", "direction" => "inbound",
                                          "created_epoch" => 1.minute.ago.to_i.to_s}]},
    "channels" => {"count" => 3, "rows" => [
      {"uuid" => "bbbb", "call_uuid" => "aaaa", "name" => "sofia/external/b-leg", "created_epoch" => "101"},
      {"uuid" => "aaaa", "call_uuid" => "aaaa", "name" => "sofia/external/a-leg", "created_epoch" => "100"},
      {"uuid" => "solo", "call_uuid" => "solo", "name" => "sofia/internal/ringing", "created_epoch" => "102"}
    ]},
    "sofia" => {"entries" => [{"kind" => "profile", "name" => "external", "data" => "sip:mod_sofia@1.2.3.4:5080", "state" => "RUNNING (0)"},
      {"kind" => "gateway", "name" => "carrier", "data" => "sip:carrier.example", "state" => "DOWN"},
      {"kind" => "alias", "name" => "1.2.3.4", "data" => "external", "state" => "ALIASED"}]}
  }.freeze

  # The group HEADING, not the Server group's "Plugins" item (the install page).
  PLUGINS_HEADING = %r{uppercase tracking-\[0\.06em\][^"]*">Plugins<}

  setup do
    @server = servers(:alpha)
    @key = @server.key
    Rails.cache.clear
  end

  def install(*plugins)
    System.create!(
      server: @server,
      payload: {host: {}, plugins: plugins.map { |name| {"name" => name, "aliases" => []} }}.to_json,
      synced_at: Time.current
    )
  end

  def with_fswapi(fake, &)
    Voodu::Client.stub(:new, fake, &)
  end

  test "without the plugin the page refuses and the Plugins group is not drawn" do
    get fswapi_path(server_key: @key)

    assert_redirected_to server_root_path(server_key: @key)
    assert_match "voodu-fswapi", flash[:alert]

    get pods_path(server_key: @key)

    assert_no_match %r{href="[^"]*/fswapi"}, @response.body
    assert_no_match PLUGINS_HEADING, @response.body
  end

  test "with the plugin the Plugins group holds the FreeSWITCH item" do
    install("fswapi")

    get pods_path(server_key: @key)

    assert_match %r{href="[^"]*/#{@key}/fswapi"}, @response.body
    assert_match PLUGINS_HEADING, @response.body
  end

  test "HEP3 moves into the Plugins group" do
    install("hep3")

    get pods_path(server_key: @key)

    assert_match PLUGINS_HEADING, @response.body
    assert_match %r{href="[^"]*/#{@key}/hep3"}, @response.body
    assert_no_match %r{href="[^"]*/fswapi"}, @response.body
  end

  test "the page shows status, the calls list and the count cards" do
    install("fswapi")

    with_fswapi(FakeFswapi.new(replies: REPLIES)) do
      get fswapi_path(server_key: @key)
    end

    assert_response :success
    assert_match "1.10.11", @response.body
    assert_match "1d 2h", @response.body
    assert_match "5511999990000", @response.body
    assert_match "Active calls", @response.body
    assert_match %r{text-\[28px\][^>]*>\s*1\s*<}m, @response.body, "the headline is the live /overview count, with no warehouse sample yet"
    assert_match "97.1% idle ≈ 2.9% in use.", @response.body
    assert_match "Back to zero on every FreeSWITCH restart.", @response.body
    assert_match %(id="#{FswapiController::FRAME}"), @response.body
  end

  test "the gateways tab shows profiles and gateways, not aliases, and frames alone" do
    install("fswapi")

    with_fswapi(FakeFswapi.new(replies: REPLIES)) do
      get fswapi_path(server_key: @key, view: "gateways"), headers: {"Turbo-Frame" => FswapiController::FRAME}
    end

    assert_response :success
    assert_match "carrier", @response.body
    assert_match "external", @response.body
    assert_no_match "ALIASED", @response.body
    assert_no_match "<aside", @response.body
  end

  test "the channels tab draws each call as a tree: A-leg, then its bridged leg" do
    install("fswapi")

    with_fswapi(FakeFswapi.new(replies: REPLIES)) do
      get fswapi_path(server_key: @key, view: "channels"), headers: {"Turbo-Frame" => FswapiController::FRAME}
    end

    assert_response :success

    body = @response.body

    assert_operator body.index("sofia/external/a-leg"), :<, body.index("sofia/external/b-leg"), "the A-leg leads its call"
    assert_match "A-leg", body
    assert_match "B-leg", body
    assert_match "2 legs", body, "the bridged call's header counts both legs"
    assert_match "1 leg<", body, "the lone ringing channel is its own call"
    assert_match "bridged to", body
    assert_match %r{>3</span> legs in .*>2</span> calls}m, body
  end

  test "the filter narrows the list, says so, and survives the polling tick" do
    install("fswapi")

    with_fswapi(FakeFswapi.new(replies: REPLIES)) do
      get fswapi_path(server_key: @key, view: "channels", q: "ringing"), headers: {"Turbo-Frame" => FswapiController::FRAME}
    end

    body = @response.body

    assert_match "sofia/internal/ringing", body
    assert_no_match "sofia/external/a-leg", body
    assert_match %r{>1</span> of .*>2</span> calls match}m, body
    assert_match %r{id="fswapi-filter"[^>]*data-turbo-permanent}m, body
    assert_match %r{href="[^"]*fswapi\?(?=[^"]*view=calls)(?=[^"]*q=ringing)}, body, "tabs keep the filter"
  end

  test "FreeSWITCH down shows the plugin's message, not a blank page" do
    install("fswapi")
    hint = "esl: authentication failed — set the event_socket password: vd config:set plugins/fswapi FREESWITCH_ESL_PASSWORD=<password>"

    with_fswapi(FakeFswapi.new(error: Voodu::Client::ServerError.new(hint))) do
      get fswapi_path(server_key: @key)
    end

    assert_response :success
    assert_match "vd config:set plugins/fswapi", CGI.unescapeHTML(@response.body)
    assert_match "Unavailable", @response.body
  end
end
