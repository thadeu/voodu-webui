# frozen_string_literal: true

require "test_helper"

# Hep3::CallFlowData turns one call's SIP messages into the ladder model.
# These pin the SHAPE the SVG depends on: request vs response classing
# (code 0 == request), lifelines by first-appearance IP, arrow labels/
# colours, and that corr_id folds B2BUA legs into ONE flow. If any of
# these invert, the ladder draws the wrong picture — so they're scenario
# tests, not mirrors of the implementation.
class Hep3::CallFlowDataTest < ActiveSupport::TestCase
  SERVER_ID = 7777
  SCOPE = "fsw"
  NAME = "hep3-api"

  SERVER = Struct.new(:id).new(SERVER_ID)

  # A realistic INVITE dialog: INVITE → 100 → 180 → 200 → ACK → BYE → 200,
  # caller 10.0.0.1 ↔ callee 10.0.0.2.
  def seed_dialog(x_cid: "call-k")
    rows = [
      req("INVITE", "10.0.0.1", "10.0.0.2", ts: 1, x_cid: x_cid, raw: "INVITE sip:bob@10.0.0.2 SIP/2.0"),
      res(100, "10.0.0.2", "10.0.0.1", ts: 2, x_cid: x_cid),
      res(180, "10.0.0.2", "10.0.0.1", ts: 3, x_cid: x_cid),
      res(200, "10.0.0.2", "10.0.0.1", ts: 4, x_cid: x_cid, raw: "SIP/2.0 200 OK"),
      req("ACK", "10.0.0.1", "10.0.0.2", ts: 5, x_cid: x_cid),
      req("BYE", "10.0.0.1", "10.0.0.2", ts: 6, x_cid: x_cid),
      res(200, "10.0.0.2", "10.0.0.1", ts: 7, x_cid: x_cid)
    ]
    HepMessage.bulk_insert(rows)
  end

  def req(method, src, dst, ts:, x_cid:, raw: "")
    line(method: method, code: 0, src: src, dst: dst, ts: ts, x_cid: x_cid, raw: raw)
  end

  def res(code, src, dst, ts:, x_cid:, raw: "")
    line(method: "", code: code, src: src, dst: dst, ts: ts, x_cid: x_cid, raw: raw)
  end

  def line(method:, code:, src:, dst:, ts:, x_cid:, raw:)
    payload = {
      ts: "2026-06-30 10:00:0#{ts}.000000", call_id: "cid-#{x_cid}", x_cid: x_cid,
      method: method, response_code: code, src_ip: src, src_port: "5060",
      dst_ip: dst, dst_port: "5060", from_user: "alice", to_user: "bob",
      cseq: "1 #{method.presence || "INVITE"}", raw_sip: raw
    }.to_json
    {server_id: SERVER_ID, scope: SCOPE, name: NAME, payload: payload}
  end

  def flow(corr_id)
    Hep3::CallFlowData.new(server: SERVER, scope: SCOPE, name: NAME, corr_id: corr_id)
  end

  test "messages are chronological with request/response classed by code" do
    seed_dialog

    data = flow("call-k")

    assert data.found?
    assert_equal 7, data.messages.size
    assert_equal %i[request provisional provisional success request terminate success],
      data.messages.map { |m| m[:kind] },
      "requests are neutral EXCEPT BYE (the call teardown), which is flagged terminate"
    assert_equal ["INVITE", "100 Trying", "180 Ringing", "200 OK", "ACK", "BYE", "200 OK"],
      data.messages.map { |m| m[:label] }
    assert_equal ["INVITE", nil, nil, nil, "ACK", "BYE", nil],
      data.messages.map { |m| m[:method] },
      "responses carry no method (that's the request side of the arrow)"
  end

  test "lifelines are the distinct parties in first-appearance order" do
    seed_dialog

    data = flow("call-k")

    assert_equal ["10.0.0.1", "10.0.0.2"], data.lifelines
    assert_equal 0, data.column_index("10.0.0.1")
    assert_equal 1, data.column_index("10.0.0.2")
  end

  test "summary reports parties, final code, count and a positive duration" do
    seed_dialog

    s = flow("call-k").summary

    assert_equal 7, s[:count]
    assert_equal 200, s[:last_code], "the last real response wins (not the 0-coded requests)"
    assert_equal "alice", s[:from_user]
    assert_equal "bob", s[:to_user]
    assert_operator s[:duration_ms], :>, 0
  end

  test "label appends (SDP) only for messages carrying an SDP body" do
    HepMessage.bulk_insert([
      {server_id: SERVER_ID, scope: SCOPE, name: NAME, payload: {
        ts: "2026-06-30 10:00:01.000000", call_id: "s", x_cid: "sdp", method: "INVITE", response_code: 0,
        raw_sip: "INVITE sip:x SIP/2.0\r\nContent-Type: application/sdp\r\nContent-Length: 8\r\n\r\nv=0\r\nm=a"
      }.to_json},
      {server_id: SERVER_ID, scope: SCOPE, name: NAME, payload: {
        ts: "2026-06-30 10:00:02.000000", call_id: "s", x_cid: "sdp", method: "", response_code: 100,
        raw_sip: "SIP/2.0 100 Trying\r\nContent-Length: 0\r\n\r\n"
      }.to_json}
    ])

    labels = flow("sdp").messages.map { |m| m[:label] }

    assert_equal ["INVITE (SDP)", "100 Trying"], labels,
      "the INVITE carries SDP (Content-Type: application/sdp); the 100 Trying doesn't"
  end

  test "media_streams derives the negotiated RTP from the offer/answer SDP" do
    invite_sdp = "INVITE sip:x SIP/2.0\r\nContent-Type: application/sdp\r\n\r\n" \
                 "v=0\r\nc=IN IP4 1.1.1.1\r\nm=audio 1000 RTP/AVP 8 96\r\n" \
                 "a=rtpmap:8 PCMA/8000\r\na=rtpmap:96 telephone-event/8000\r\na=sendrecv"
    ok_sdp = "SIP/2.0 200 OK\r\nContent-Type: application/sdp\r\n\r\n" \
             "v=0\r\nc=IN IP4 2.2.2.2\r\nm=audio 2000 RTP/AVP 8\r\na=rtpmap:8 PCMA/8000\r\na=sendrecv"

    HepMessage.bulk_insert([
      {server_id: SERVER_ID, scope: SCOPE, name: NAME, payload: {ts: "2026-06-30 10:00:01.000000", call_id: "leg1", x_cid: "m", method: "INVITE", response_code: 0, raw_sip: invite_sdp}.to_json},
      {server_id: SERVER_ID, scope: SCOPE, name: NAME, payload: {ts: "2026-06-30 10:00:02.000000", call_id: "leg1", x_cid: "m", method: "", response_code: 100, raw_sip: "SIP/2.0 100 Trying\r\nContent-Length: 0"}.to_json},
      {server_id: SERVER_ID, scope: SCOPE, name: NAME, payload: {ts: "2026-06-30 10:00:03.000000", call_id: "leg1", x_cid: "m", method: "", response_code: 200, raw_sip: ok_sdp}.to_json}
    ])

    streams = flow("m").media_streams

    assert_equal 1, streams.size, "one media stream per leg (offer+answer)"
    s = streams.first
    assert_equal "1.1.1.1:1000", s[:offer]
    assert_equal "2.2.2.2:2000", s[:answer]
    assert_equal ["PCMA/8000"], s[:codecs], "the answer's agreed codec (resolved via a=rtpmap)"
    assert_equal "sendrecv", s[:direction]
    assert s[:answered]
  end

  test "media_streams is empty when no message carries SDP" do
    seed_dialog # its raws have no Content-Type: application/sdp

    assert_empty flow("call-k").media_streams
  end

  def sdp_raw(start_line, media_ip, port)
    "#{start_line}\r\nContent-Type: application/sdp\r\n\r\n" \
      "v=0\r\nc=IN IP4 #{media_ip}\r\nm=audio #{port} RTP/AVP 8\r\na=rtpmap:8 PCMA/8000\r\na=sendrecv"
  end

  test "media BETWEEN lifelines is inline (has from/to cols); off-lifeline is a gap" do
    # signalling 1.1.1.1 ⇄ 2.2.2.2 (the lifelines); media c= is ALSO on them.
    HepMessage.bulk_insert([
      req("INVITE", "1.1.1.1", "2.2.2.2", ts: 1, x_cid: "inl", raw: sdp_raw("INVITE sip:x SIP/2.0", "1.1.1.1", 1000)),
      res(200, "2.2.2.2", "1.1.1.1", ts: 2, x_cid: "inl", raw: sdp_raw("SIP/2.0 200 OK", "2.2.2.2", 2000))
    ])

    data = flow("inl")

    assert_equal ["1.1.1.1", "2.2.2.2"], data.lifelines
    assert_equal 1, data.inline_media.size, "both media endpoints are lifelines → draw in the ladder"
    assert_equal [0, 1], data.inline_media.first.values_at(:from_col, :to_col)
    assert_empty data.gap_media
  end

  test "media on an off-lifeline host is a gap (footer), never inline" do
    # answer media 9.9.9.9 isn't a signalling party → can't sit in the ladder.
    HepMessage.bulk_insert([
      req("INVITE", "1.1.1.1", "2.2.2.2", ts: 1, x_cid: "gp", raw: sdp_raw("INVITE sip:x SIP/2.0", "1.1.1.1", 1000)),
      res(200, "2.2.2.2", "1.1.1.1", ts: 2, x_cid: "gp", raw: sdp_raw("SIP/2.0 200 OK", "9.9.9.9", 2000))
    ])

    data = flow("gp")

    assert_empty data.inline_media
    assert_equal 1, data.gap_media.size
  end

  test "raw_sip survives intact for the drawer panel" do
    seed_dialog

    invite = flow("call-k").messages.first

    assert_equal "INVITE sip:bob@10.0.0.2 SIP/2.0", invite[:raw_sip]
  end

  test "focus_id pre-selects the clicked message; nil/unknown falls to the first" do
    seed_dialog

    target = flow("call-k").messages[3] # the 200 OK
    focused = Hep3::CallFlowData.new(server: SERVER, scope: SCOPE, name: NAME, corr_id: "call-k", focus_id: target[:id])

    assert_equal 3, focused.focus_index
    assert_equal target[:id], focused.focus_message[:id]

    assert_equal 0, flow("call-k").focus_index, "no focus → opens at the call's first message"
    assert_equal 0, Hep3::CallFlowData.new(server: SERVER, scope: SCOPE, name: NAME, corr_id: "call-k", focus_id: 999_999).focus_index,
      "a focus id that isn't in this call (e.g. a Calls-view aggregate row) → first"
  end

  test "an unknown corr_id is not found" do
    seed_dialog

    refute flow("nope").found?
    assert_empty flow("nope").messages
  end

  test "corr_id folds B2BUA legs (shared x_cid, different call_ids) into one flow" do
    HepMessage.bulk_insert([
      req("INVITE", "10.0.0.1", "10.0.0.9", ts: 1, x_cid: "shared").merge(payload: leg_payload("legA", "shared", 1)),
      req("INVITE", "10.0.0.9", "10.0.0.2", ts: 2, x_cid: "shared").merge(payload: leg_payload("legB", "shared", 2))
    ])

    data = flow("shared")

    assert_equal 2, data.messages.size, "both legs collapse under the shared x_cid"
    assert_equal ["10.0.0.1", "10.0.0.9", "10.0.0.2"], data.lifelines
  end

  def leg_payload(call_id, x_cid, ts)
    {
      ts: "2026-06-30 10:00:0#{ts}.000000", call_id: call_id, x_cid: x_cid,
      method: "INVITE", response_code: 0,
      src_ip: ((ts == 1) ? "10.0.0.1" : "10.0.0.9"), src_port: "5060",
      dst_ip: ((ts == 1) ? "10.0.0.9" : "10.0.0.2"), dst_port: "5060",
      from_user: "alice", to_user: "bob", cseq: "1 INVITE", raw_sip: ""
    }.to_json
  end
end
