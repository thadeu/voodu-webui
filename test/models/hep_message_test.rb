# frozen_string_literal: true

require "test_helper"

# HepMessage's correlation key (corr_id) is what stitches a call together
# for the call-flow ladder. These pin the semantics: x_cid wins so B2BUA
# legs with DIFFERENT Call-IDs join, and a leg with no x_cid falls back
# to its own call_id. Also covers HepCursor's upsert watermark.
class HepMessageTest < ActiveSupport::TestCase
  # A real Server: the readers take one and refuse an id (see ServerScoped).
  # The WRITE path keeps taking ids — bulk_insert is the poller's, and the
  # poller is machine-side.
  def server = servers(:alpha)

  def server_id = server.id
  SCOPE = "fsw"
  NAME = "hep3-api"

  def insert(call_id:, x_cid: "", method: "INVITE", code: 0, ts: "2026-06-30 10:00:00.000000")
    line = {ts: ts, call_id: call_id, x_cid: x_cid, method: method, response_code: code}.to_json
    HepMessage.bulk_insert([{server_id: server_id, scope: SCOPE, name: NAME, payload: line}])
  end

  def for_call(corr_id)
    HepMessage.for_call(server: server, scope: SCOPE, name: NAME, corr_id: corr_id)
  end

  test "corr_id groups B2BUA legs that share an x_cid (different call_ids)" do
    insert(call_id: "legA@sbc", x_cid: "shared-cid", ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "legB@fsw", x_cid: "shared-cid", ts: "2026-06-30 10:00:02.000000")
    insert(call_id: "unrelated", x_cid: "", ts: "2026-06-30 10:00:03.000000")

    grouped = for_call("shared-cid")

    assert_equal %w[legA@sbc legB@fsw], grouped.map(&:call_id).sort,
      "both legs (distinct Call-IDs) must collapse under the shared x_cid"
  end

  # Production shape (fsw, 2026-09-17): the INVITE carried the upstream SBC's
  # X-CID, the 100/180/403/ACK of the SAME Call-ID carried none. Per-message
  # corr_id split one dialog in two; the ladder must show all five whichever
  # key opens it.
  test "a dialog whose INVITE alone carries an x_cid is one call from either key" do
    insert(call_id: "dlg@fsw", x_cid: "SBC+158109034@10.11.164.48", method: "INVITE", ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "dlg@fsw", x_cid: "", method: "", code: 100, ts: "2026-06-30 10:00:02.000000")
    insert(call_id: "dlg@fsw", x_cid: "", method: "", code: 403, ts: "2026-06-30 10:00:03.000000")
    insert(call_id: "dlg@fsw", x_cid: "", method: "ACK", ts: "2026-06-30 10:00:04.000000")
    insert(call_id: "other@fsw", x_cid: "", method: "INVITE", ts: "2026-06-30 10:00:05.000000")

    by_call_id = for_call("dlg@fsw").map(&:sip_method)
    by_x_cid = for_call("SBC+158109034@10.11.164.48").map(&:sip_method)

    assert_equal ["INVITE", "", "", "ACK"], by_call_id, "opened by Call-ID: the INVITE must be there"
    assert_equal by_call_id, by_x_cid, "opened by X-CID: same five messages"
  end

  test "the correlation walk also joins a B2BUA whose legs only share the x_cid on some messages" do
    insert(call_id: "A", x_cid: "shared", method: "INVITE", ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "A", x_cid: "", method: "", code: 200, ts: "2026-06-30 10:00:02.000000")
    insert(call_id: "B", x_cid: "shared", method: "INVITE", ts: "2026-06-30 10:00:03.000000")
    insert(call_id: "B", x_cid: "", method: "BYE", ts: "2026-06-30 10:00:04.000000")

    assert_equal %w[A A B B], for_call("A").map(&:call_id)
  end

  test "corr_id falls back to call_id when x_cid is blank" do
    insert(call_id: "solo@x", x_cid: "")

    assert_equal 1, for_call("solo@x").count, "no x_cid → the call is keyed by its Call-ID"
    assert_equal 0, for_call("").count, "blank corr_id must not match the row"
  end

  test "for_call returns the call's messages in chronological order" do
    insert(call_id: "c", x_cid: "k", method: "BYE", code: 0, ts: "2026-06-30 10:00:05.000000")
    insert(call_id: "c", x_cid: "k", method: "INVITE", code: 0, ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "c", x_cid: "k", method: "", code: 200, ts: "2026-06-30 10:00:03.000000")

    assert_equal ["INVITE", "", "BYE"], for_call("k").map(&:sip_method),
      "ladder order follows ts, not insertion order"
  end

  test "for_call orders by SUB-SECOND ts, not arrival id, when ts_epoch ties" do
    # A whole dialog lands in the same second. The 100 Trying is INSERTED
    # first (lower id) but happened AFTER the INVITE in microseconds — the
    # ladder must still start at the INVITE. ts_epoch (seconds) would tie and
    # fall back to id, drawing the 100 first (the bug this pins).
    insert(call_id: "d", x_cid: "z", method: "", code: 100, ts: "2026-06-30 10:00:01.500000")
    insert(call_id: "d", x_cid: "z", method: "INVITE", code: 0, ts: "2026-06-30 10:00:01.100000")

    assert_equal ["INVITE", ""], for_call("z").map(&:sip_method),
      "same second → earlier microsecond ts wins over later arrival id"
  end

  test "a `like /re/` filter runs through SQLite REGEXP — anchors work, registered lazily (no initializer)" do
    {"12997297095" => "a", "551125019444" => "b", "998877" => "c"}.each do |from_user, cid|
      line = {ts: "2026-06-30 10:00:00.000000", call_id: cid, from_user: from_user, method: "INVITE"}.to_json
      HepMessage.bulk_insert([{server_id: server_id, scope: SCOPE, name: NAME, payload: line}])
    end

    assert_equal %w[12997297095 551125019444].sort, matches("@from_user like /12/").sort,
      "unanchored /12/ matches any number containing 12"
    assert_equal ["12997297095"], matches("@from_user like /^12/"),
      "anchored /^12/ matches only the number that STARTS with 12 — real regex, not substring"
  end

  def matches(query)
    compiled = DataTable::Query.compile(query) { |f| HepMessage.filter_expr(f) }
    HepMessage.page(server: server, scope: SCOPE, name: NAME, where_sql: compiled.sql, where_binds: compiled.binds)
      .map { |r| r.payload_json["from_user"] }
  end

  test "HepCursor.advance upserts; cursor_for reads it back" do
    assert_equal "", HepCursor.cursor_for(server, SCOPE, NAME), "empty before the first poll"

    HepCursor.advance(server, SCOPE, NAME, "sip-2026-06-30.ndjson:100")
    assert_equal "sip-2026-06-30.ndjson:100", HepCursor.cursor_for(server, SCOPE, NAME)

    HepCursor.advance(server, SCOPE, NAME, "sip-2026-06-30.ndjson:250")
    assert_equal "sip-2026-06-30.ndjson:250", HepCursor.cursor_for(server, SCOPE, NAME)
    assert_equal 1, HepCursor.where(server_id: server_id, scope: SCOPE, name: NAME).count,
      "advance upserts the single watermark row, never appends"
  end

  # ── call_key: the call's identity, resolved at ingest ──────────────────

  def calls_count
    HepMessage.for_instance(server: server, scope: SCOPE, name: NAME).distinct.count(:call_key)
  end

  test "the production dialog counts as ONE call: INVITE with x_cid, the rest without" do
    insert(call_id: "dlg", x_cid: "", method: "", code: 100, ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "dlg", x_cid: "SBC+1", method: "INVITE", ts: "2026-06-30 10:00:00.900000")
    insert(call_id: "dlg", x_cid: "", method: "", code: 403, ts: "2026-06-30 10:00:02.000000")
    insert(call_id: "dlg", x_cid: "", method: "ACK", ts: "2026-06-30 10:00:03.000000")

    assert_equal 1, calls_count
    assert_equal ["dlg"], HepMessage.distinct.pluck(:call_key)
  end

  test "gateway failover: a new Call-ID carrying the same x_cid joins the call" do
    insert(call_id: "try1", x_cid: "SBC+1", method: "INVITE", ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "try1", x_cid: "", method: "", code: 403, ts: "2026-06-30 10:00:02.000000")
    insert(call_id: "try2", x_cid: "SBC+1", method: "INVITE", ts: "2026-06-30 10:00:03.000000")
    insert(call_id: "try2", x_cid: "", method: "", code: 200, ts: "2026-06-30 10:00:04.000000")
    insert(call_id: "other", x_cid: "", method: "INVITE", ts: "2026-06-30 10:00:05.000000")

    assert_equal 2, calls_count
    assert_equal 4, for_call("try2").count, "opened from the second attempt: the whole call"
    assert_equal 4, for_call("SBC+1").count, "opened by the X-CID: the whole call"
  end

  test "union: a leg tailed before the INVITE that links it is folded into one key" do
    # B-leg responses land first (their own key), then the A-leg INVITE that
    # carries the X-CID, then the B-leg INVITE that ALSO carries it — at that
    # point the table holds two keys for one call and must merge them.
    insert(call_id: "B", x_cid: "", method: "", code: 180, ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "A", x_cid: "shared", method: "INVITE", ts: "2026-06-30 10:00:00.500000")
    insert(call_id: "B", x_cid: "shared", method: "INVITE", ts: "2026-06-30 10:00:00.900000")

    assert_equal 1, calls_count
    assert_equal 3, for_call("B").count
    assert_equal 3, for_call("A").count
  end

  test "backfill_call_keys! rewrites split keys the migration seeded from corr_id" do
    insert(call_id: "dlg", x_cid: "SBC+9", method: "INVITE", ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "dlg", x_cid: "", method: "", code: 100, ts: "2026-06-30 10:00:02.000000")
    insert(call_id: "leg2", x_cid: "SBC+9", method: "INVITE", ts: "2026-06-30 10:00:03.000000")

    # Simulate the pre-column state: every row keyed by its own corr_id.
    HepMessage.update_all("call_key = corr_id")
    assert_equal 2, calls_count, "seeded from corr_id the dialog is split"

    rewritten = HepMessage.backfill_call_keys!

    assert_equal 1, calls_count
    assert_operator rewritten, :>=, 1
    assert_equal 0, HepMessage.backfill_call_keys!, "idempotent: a second pass rewrites nothing"
  end

  test "backfill_call_keys! rewrites a leg keyed BEFORE the union that links it" do
    # Leg A first (keyed A), leg B responses next (keyed B), and only then the
    # B-leg INVITE that carries A's x_cid — the union comes after both legs
    # were keyed. One pass would leave leg A on the loser key.
    insert(call_id: "A", x_cid: "link", method: "INVITE", ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "A", x_cid: "", method: "", code: 200, ts: "2026-06-30 10:00:02.000000")
    insert(call_id: "B", x_cid: "", method: "", code: 180, ts: "2026-06-30 10:00:03.000000")
    insert(call_id: "B", x_cid: "link", method: "INVITE", ts: "2026-06-30 10:00:02.500000")

    HepMessage.update_all("call_key = corr_id")
    assert_equal 3, calls_count, "seeded from corr_id: A, B and the x_cid"

    HepMessage.backfill_call_keys!

    assert_equal 1, calls_count
    assert_equal 4, for_call("A").count
    assert_equal 4, for_call("B").count
  end

  test "for_call shows every message sharing a Call-ID even when call_key is inconsistent" do
    insert(call_id: "dlg", x_cid: "", method: "INVITE", ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "dlg", x_cid: "", method: "", code: 200, ts: "2026-06-30 10:00:02.000000")
    insert(call_id: "dlg", x_cid: "", method: "ACK", ts: "2026-06-30 10:00:03.000000")

    # Damage the keys on purpose: whatever split them, the ladder must not care.
    HepMessage.where(sip_method: "INVITE").update_all(call_key: "stray")

    assert_equal 3, for_call("dlg").count, "opened by Call-ID"
    assert_equal 3, for_call("stray").count, "opened by the stray key still reaches the whole dialog"
  end

  # FSW-ESL sends `X-CID: unknown` on every outbound INVITE (prod, 2026-09-17).
  # The collector stores it verbatim; the console must not treat it as a link.
  test "a sentinel x_cid (unknown) never joins unrelated calls" do
    insert(call_id: "out1", x_cid: "unknown", method: "INVITE", ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "out1", x_cid: "", method: "", code: 200, ts: "2026-06-30 10:00:02.000000")
    insert(call_id: "out2", x_cid: "unknown", method: "INVITE", ts: "2026-06-30 10:00:03.000000")
    insert(call_id: "out2", x_cid: "", method: "", code: 486, ts: "2026-06-30 10:00:04.000000")

    assert_equal 2, calls_count, "two outbound calls stay two"
    assert_equal 2, for_call("out1").count
    assert_equal 2, for_call("out2").count
    assert_equal 0, for_call("unknown").count, "opening by the sentinel shows nothing, not everything"
  end
end
