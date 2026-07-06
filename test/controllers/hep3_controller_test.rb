# frozen_string_literal: true

require "test_helper"

# Hep3Controller#call returns the call-flow ladder overlay for one call.
# Pins: the fragment renders (no layout), the ladder carries the call's
# messages, a not-found call still renders the in-overlay empty state
# (never a dead click), and missing params 404.
class Hep3ControllerTest < ActionDispatch::IntegrationTest
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @key = @server.key
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"

    HepMessage.bulk_insert([
      msg("INVITE", 0, "10.0.0.1", "10.0.0.2", ts: "01", raw: "INVITE sip:bob@10.0.0.2 SIP/2.0"),
      msg("", 100, "10.0.0.2", "10.0.0.1", ts: "02"),
      msg("", 200, "10.0.0.2", "10.0.0.1", ts: "03", raw: "SIP/2.0 200 OK"),
      msg("ACK", 0, "10.0.0.1", "10.0.0.2", ts: "04")
    ])
  end

  teardown { ENV["WAREHOUSE"] = @prev_wh }

  def msg(method, code, src, dst, ts:, raw: "", corr: "call-1")
    payload = {
      ts: "2026-06-30 10:00:#{ts}.000000", call_id: corr, x_cid: "",
      method: method, response_code: code, src_ip: src, dst_ip: dst,
      src_port: "5060", dst_port: "5060", from_user: "alice", to_user: "bob", raw_sip: raw
    }.to_json
    {server_id: @server.id, scope: "fsw", name: "hep3-api", payload: payload}
  end

  def sdp_raw(start_line, ip, port)
    "#{start_line}\r\nContent-Type: application/sdp\r\n\r\n" \
      "v=0\r\nc=IN IP4 #{ip}\r\nm=audio #{port} RTP/AVP 8\r\na=rtpmap:8 PCMA/8000\r\na=sendrecv"
  end

  test "renders the ladder fragment for a call (no layout)" do
    get metrics_hep3_call_path(server_key: @key, scope: "fsw", name: "hep3-api", corr_id: "call-1")

    assert_response :success
    assert_match(/<svg/, @response.body, "the ladder is an inline SVG")
    assert_match "INVITE", @response.body
    assert_match "200 OK", @response.body
    assert_match "alice → bob", @response.body, "the header shows the parties"
    assert_no_match(/<html/, @response.body, "layout: false — a bare fragment for injection")
  end

  test "carries the raw SIP so the panel needs no extra fetch" do
    get metrics_hep3_call_path(server_key: @key, scope: "fsw", name: "hep3-api", corr_id: "call-1")

    assert_response :success
    assert_match "INVITE sip:bob@10.0.0.2 SIP/2.0", @response.body,
      "the first message's raw SIP is seeded into the panel"
  end

  test "focus pre-selects the clicked message (server emits its ladder index)" do
    ok = HepMessage.for_call(server_id: @server.id, scope: "fsw", name: "hep3-api", corr_id: "call-1")
      .find { |m| m.payload_json["response_code"] == 200 }

    get metrics_hep3_call_path(server_key: @key, scope: "fsw", name: "hep3-api", corr_id: "call-1", focus: ok.id)

    assert_response :success
    # ladder order: INVITE(0) 100(1) 200(2) ACK(3) → the 200 is index 2.
    assert_match 'data-call-flow-focus-value="2"', @response.body,
      "the clicked message's index is emitted so the ladder opens on it"
  end

  test "the fragment wires refresh + keyboard nav (scope/corr values, actions)" do
    get metrics_hep3_call_path(server_key: @key, scope: "fsw", name: "hep3-api", corr_id: "call-1")

    assert_response :success
    assert_match 'data-call-flow-corr-value="call-1"', @response.body
    assert_match 'data-call-flow-scope-value="fsw"', @response.body
    assert_match "call-flow#refresh", @response.body, "the Refresh button re-fetches the call in place"
    assert_match "call-flow#ladderEnter", @response.body, "the diagram arms ↑/↓ keyboard nav on hover"
  end

  test "media between lifelines is drawn inline in the ladder SVG" do
    HepMessage.bulk_insert([
      msg("INVITE", 0, "1.1.1.1", "2.2.2.2", ts: "01", corr: "inl", raw: sdp_raw("INVITE sip:x SIP/2.0", "1.1.1.1", 1000)),
      msg("", 200, "2.2.2.2", "1.1.1.1", ts: "02", corr: "inl", raw: sdp_raw("SIP/2.0 200 OK", "2.2.2.2", 2000))
    ])

    get metrics_hep3_call_path(server_key: @key, scope: "fsw", name: "hep3-api", corr_id: "inl")

    assert_response :success
    assert_match "call-flow-media", @response.body, "on-lifeline RTP is drawn inline in the ladder"
    assert_match "RTP PCMA", @response.body
  end

  test "Logs bridge: a SIP call_id resolves to the folded call (x_cid), any reader" do
    # Two B2BUA legs share x_cid "shared" but have DIFFERENT Call-IDs; a log
    # line only ever carries one leg's Call-ID. Opening by it must resolve the
    # reader instance + corr_id (= shared) and show the WHOLE call.
    HepMessage.bulk_insert([
      {server_id: @server.id, scope: "fsw", name: "hep3-api", payload: {
        ts: "2026-06-30 10:00:01.000000", call_id: "legA@sbc", x_cid: "shared",
        method: "INVITE", response_code: 0, src_ip: "1.1.1.1", dst_ip: "2.2.2.2", from_user: "a", to_user: "b"
      }.to_json},
      {server_id: @server.id, scope: "fsw", name: "hep3-api", payload: {
        ts: "2026-06-30 10:00:02.000000", call_id: "legB@fsw", x_cid: "shared",
        method: "", response_code: 200, src_ip: "2.2.2.2", dst_ip: "1.1.1.1", from_user: "a", to_user: "b"
      }.to_json}
    ])

    get metrics_hep3_call_path(server_key: @key, call_id: "legA@sbc")

    assert_response :success
    assert_match(/<svg/, @response.body)
    assert_match "INVITE", @response.body
    assert_match "200 OK", @response.body, "both legs (folded by x_cid) render, not just leg A"
    assert_no_match(/Call not found/, @response.body)
  end

  test "Logs bridge: an uncaptured call_id renders the empty state carrying the id" do
    get metrics_hep3_call_path(server_key: @key, call_id: "never-captured@10.0.0.9")

    assert_response :success
    assert_match "Call not found", @response.body
    assert_match "never-captured@10.0.0.9", @response.body
  end

  test "an unknown call renders the in-overlay empty state, not a 404" do
    get metrics_hep3_call_path(server_key: @key, scope: "fsw", name: "hep3-api", corr_id: "ghost")

    assert_response :success
    assert_match "Call not found", @response.body
  end

  test "missing scope/name/corr_id is a 404" do
    get metrics_hep3_call_path(server_key: @key, scope: "", name: "", corr_id: "")

    assert_response :not_found
  end
end
