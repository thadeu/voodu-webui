# frozen_string_literal: true

require "test_helper"

# HepMessage's correlation key (corr_id) is what stitches a call together
# for the call-flow ladder. These pin the semantics: x_cid wins so B2BUA
# legs with DIFFERENT Call-IDs join, and a leg with no x_cid falls back
# to its own call_id. Also covers HepCursor's upsert watermark.
class HepMessageTest < ActiveSupport::TestCase
  TENANT = 4242
  SCOPE = "fsw"
  NAME = "hep3-api"

  def insert(call_id:, x_cid: "", method: "INVITE", code: 0, ts: "2026-06-30 10:00:00.000000")
    line = {ts: ts, call_id: call_id, x_cid: x_cid, method: method, response_code: code}.to_json
    HepMessage.bulk_insert([{tenant_id: TENANT, scope: SCOPE, name: NAME, payload: line}])
  end

  def for_call(corr_id)
    HepMessage.for_call(tenant_id: TENANT, scope: SCOPE, name: NAME, corr_id: corr_id)
  end

  test "corr_id groups B2BUA legs that share an x_cid (different call_ids)" do
    insert(call_id: "legA@sbc", x_cid: "shared-cid", ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "legB@fsw", x_cid: "shared-cid", ts: "2026-06-30 10:00:02.000000")
    insert(call_id: "unrelated", x_cid: "", ts: "2026-06-30 10:00:03.000000")

    grouped = for_call("shared-cid")

    assert_equal %w[legA@sbc legB@fsw], grouped.map(&:call_id).sort,
      "both legs (distinct Call-IDs) must collapse under the shared x_cid"
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

  test "a `like /re/` filter runs through SQLite REGEXP — anchors work, registered lazily (no initializer)" do
    {"12997297095" => "a", "551125019444" => "b", "998877" => "c"}.each do |from_user, cid|
      line = {ts: "2026-06-30 10:00:00.000000", call_id: cid, from_user: from_user, method: "INVITE"}.to_json
      HepMessage.bulk_insert([{tenant_id: TENANT, scope: SCOPE, name: NAME, payload: line}])
    end

    assert_equal %w[12997297095 551125019444].sort, matches("@from_user like /12/").sort,
      "unanchored /12/ matches any number containing 12"
    assert_equal ["12997297095"], matches("@from_user like /^12/"),
      "anchored /^12/ matches only the number that STARTS with 12 — real regex, not substring"
  end

  def matches(query)
    compiled = DataTable::Query.compile(query) { |f| HepMessage.filter_expr(f) }
    HepMessage.page(tenant_id: TENANT, scope: SCOPE, name: NAME, where_sql: compiled.sql, where_binds: compiled.binds)
      .map { |r| r.payload_json["from_user"] }
  end

  test "HepCursor.advance upserts; cursor_for reads it back" do
    assert_equal "", HepCursor.cursor_for(TENANT, SCOPE, NAME), "empty before the first poll"

    HepCursor.advance(TENANT, SCOPE, NAME, "sip-2026-06-30.ndjson:100")
    assert_equal "sip-2026-06-30.ndjson:100", HepCursor.cursor_for(TENANT, SCOPE, NAME)

    HepCursor.advance(TENANT, SCOPE, NAME, "sip-2026-06-30.ndjson:250")
    assert_equal "sip-2026-06-30.ndjson:250", HepCursor.cursor_for(TENANT, SCOPE, NAME)
    assert_equal 1, HepCursor.where(tenant_id: TENANT, scope: SCOPE, name: NAME).count,
      "advance upserts the single watermark row, never appends"
  end
end
