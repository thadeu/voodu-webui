# frozen_string_literal: true

require "test_helper"

# DataTable::Hep3Source feeds the generic Table panel from the local read
# model. These pin the three views' semantics: messages = flat rows
# (id + corr_id, no raw_sip), errors = only 4xx/5xx, calls = one grouped
# row per corr_id with a message count.
class DataTable::Hep3SourceTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @scope = "fsw"
    @name = "hep3-api"
    @src = DataTable::Hep3Source.new(server: @server, scope: @scope, name: @name)
  end

  def insert(call_id:, x_cid: "", meth: "INVITE", code: 0, ts: "2026-06-30 10:00:00.000000", raw: "X sip:y")
    payload = {ts: ts, call_id: call_id, x_cid: x_cid, method: meth, response_code: code, raw_sip: raw}.to_json
    HepMessage.bulk_insert([{server_id: @server.id, scope: @scope, name: @name, payload: payload}])
  end

  test "views lists messages, calls and errors" do
    assert_equal %w[messages calls errors], @src.views.map { |v| v[:key] }
  end

  test "messages view returns flat rows with id + corr_id and no raw_sip" do
    insert(call_id: "c1", x_cid: "xc1", meth: "INVITE")

    row = @src.rows(view: "messages").first

    assert_equal "INVITE", row["method"]
    assert_equal "xc1", row["corr_id"], "corr_id derives from x_cid"
    assert row["id"].present?
    assert_not row.key?("raw_sip"), "raw_sip is shown in the drawer, not a cell"
  end

  test "errors view returns only responses with code >= 400" do
    insert(call_id: "ok", meth: "", code: 200, ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "bad", meth: "", code: 486, ts: "2026-06-30 10:00:02.000000")
    insert(call_id: "bad2", meth: "", code: 603, ts: "2026-06-30 10:00:03.000000")

    codes = @src.rows(view: "errors").map { |r| r["response_code"] }

    assert_equal [603, 486], codes, "newest-first, only 4xx/5xx"
  end

  test "calls view groups messages by corr_id with a message count" do
    insert(call_id: "legA", x_cid: "shared", meth: "INVITE", ts: "2026-06-30 10:00:01.000000")
    insert(call_id: "legB", x_cid: "shared", meth: "ACK", ts: "2026-06-30 10:00:02.000000")
    insert(call_id: "solo", x_cid: "", meth: "OPTIONS", ts: "2026-06-30 10:00:03.000000")

    rows = @src.rows(view: "calls")
    by_corr = rows.to_h { |r| [r["corr_id"], r] }

    assert_equal 2, by_corr["shared"]["messages"], "both legs collapse under the shared x_cid"
    assert_equal 1, by_corr["solo"]["messages"]
    assert by_corr["shared"]["id"].present?, "calls expose a numeric cursor id (MAX ts_epoch)"
  end

  test "fields differ between messages and calls views" do
    assert_includes @src.fields(view: "messages"), "method"
    assert_includes @src.fields(view: "calls"), "messages"
    assert_not_includes @src.fields(view: "calls"), "method"
  end

  test "from_params requires a scope and name" do
    assert_nil DataTable::Hep3Source.from_params(server: @server, params: {scope: "fsw"})
    assert DataTable::Hep3Source.from_params(server: @server, params: {scope: "fsw", name: "hep3-api"})
  end

  # ── group-by aggregation (M2) ───────────────────────────────────────────────
  # The pipeline QL (M1) → SQL GROUP BY. Snapshot for Table/Bar/Number; series
  # for Line/Area. Parser + SQL exercised end-to-end via QueryPlan.compile.

  T0 = "2026-06-30 10:00:00.000000"
  T1 = "2026-06-30 10:01:00.000000"
  EPOCH0 = Time.utc(2026, 6, 30, 10, 0, 0).to_i
  WIDE = {ts_from: 0, ts_to: 99_999_999_999}.freeze

  def ins(to_user:, corr:, meth: "INVITE", code: 0, ts: T0)
    payload = {ts: ts, call_id: corr, x_cid: corr, to_user: to_user, method: meth, response_code: code}.to_json
    HepMessage.bulk_insert([{server_id: @server.id, scope: @scope, name: @name, payload: payload}])
  end

  def plan(src) = DataTable::QueryPlan.compile(src)

  def seed_group_data
    ins(to_user: "A", corr: "c1")
    ins(to_user: "A", corr: "c2")
    ins(to_user: "A", corr: "c3")  # A: 3 messages, 3 distinct calls
    ins(to_user: "C", corr: "c4")
    ins(to_user: "C", corr: "c4")  # C: 2 messages, 1 distinct call
    ins(to_user: "B", corr: "c5")  # B: 1 message,  1 distinct call
  end

  test "count() by to_user → snapshot, one value per number, sorted desc" do
    seed_group_data

    snap = @src.grouped_snapshot(plan("| count() by to_user"), **WIDE)

    assert_equal [{group: "A", value: 3}, {group: "C", value: 2}, {group: "B", value: 1}], snap
  end

  test "limit caps the snapshot to the top-N groups" do
    seed_group_data

    snap = @src.grouped_snapshot(plan("| count() by to_user | sort desc | limit 2"), **WIDE)

    assert_equal %w[A C], snap.map { |g| g[:group] }, "top 2 by count"
  end

  test "sort asc flips the order" do
    seed_group_data

    snap = @src.grouped_snapshot(plan("| count() by to_user | sort asc"), **WIDE)

    assert_equal %w[B C A], snap.map { |g| g[:group] }
  end

  test "count(distinct corr_id) by to_user counts distinct CALLS per number" do
    seed_group_data

    snap = @src.grouped_snapshot(plan("| count(distinct corr_id) by to_user"), **WIDE)
    by = snap.to_h { |g| [g[:group], g[:value]] }

    assert_equal 3, by["A"], "A had 3 distinct calls (c1/c2/c3)"
    assert_equal 1, by["C"], "C's two messages share one call (c4)"
    assert_equal 1, by["B"]
  end

  test "the filter stage narrows the rows before grouping" do
    seed_group_data
    ins(to_user: "A", corr: "c9", meth: "BYE")  # extra A row, but a BYE

    snap = @src.grouped_snapshot(plan("@method = INVITE | count() by to_user"), **WIDE)
    by = snap.to_h { |g| [g[:group], g[:value]] }

    assert_equal 3, by["A"], "the BYE is filtered out — only the 3 INVITEs count"
  end

  test "a group field outside the allowlist yields nothing (no injection)" do
    seed_group_data

    assert_empty @src.grouped_snapshot(plan("| count() by bogus_field"), **WIDE)
  end

  test "the Calls view makes count() count distinct CALLS, not messages" do
    seed_group_data  # A: 3 msgs / 3 calls · C: 2 msgs / 1 call · B: 1 / 1

    msgs = @src.grouped_snapshot(plan("| count() by to_user"), view: "messages", **WIDE)
    calls = @src.grouped_snapshot(plan("| count() by to_user"), view: "calls", **WIDE)

    assert_equal({"A" => 3, "C" => 2, "B" => 1}, msgs.to_h { |g| [g[:group], g[:value]] })
    assert_equal({"A" => 3, "C" => 1, "B" => 1}, calls.to_h { |g| [g[:group], g[:value]] },
      "C's two messages collapse to one call")
  end

  test "the Errors view counts only 4xx/5xx rows" do
    ins(to_user: "A", corr: "e1", code: 200)
    ins(to_user: "A", corr: "e2", code: 486)
    ins(to_user: "A", corr: "e3", code: 503)
    ins(to_user: "B", corr: "e4", code: 200)

    by = @src.grouped_snapshot(plan("| count() by to_user"), view: "errors", **WIDE)
      .to_h { |g| [g[:group], g[:value]] }

    assert_equal 2, by["A"], "only the 486 + 503 count as errors"
    assert_nil by["B"], "B had only a 200 → no error rows → not a group"
  end

  test "an explicit count(distinct X) overrides the view's default metric" do
    seed_group_data

    # messages view, but the query asks for distinct calls → distinct calls wins
    by = @src.grouped_snapshot(plan("| count(distinct corr_id) by to_user"), view: "messages", **WIDE)
      .to_h { |g| [g[:group], g[:value]] }

    assert_equal({"A" => 3, "C" => 1, "B" => 1}, by)
  end

  test "grouped_series builds one bucketed series per top-N group, in snapshot order" do
    ins(to_user: "A", corr: "a1", ts: T0)
    ins(to_user: "A", corr: "a2", ts: T0)
    ins(to_user: "A", corr: "a3", ts: T1)  # A: 2 @ bucket0, 1 @ bucket1
    ins(to_user: "B", corr: "b1", ts: T0)  # B: 1 @ bucket0

    series = @src.grouped_series(
      plan("| count() by to_user | sort desc"),
      ts_from: EPOCH0, ts_to: EPOCH0 + 120, bucket: 60
    )

    assert_equal %w[A B], series.keys, "series ordered by the snapshot (A has more)"
    assert_equal [[EPOCH0, 2], [EPOCH0 + 60, 1]], series["A"]
    assert_equal [[EPOCH0, 1]], series["B"]
  end
end
