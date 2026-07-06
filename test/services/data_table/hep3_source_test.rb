# frozen_string_literal: true

require "test_helper"

# DataTable::Hep3Source feeds the generic Table panel from the local read
# model. These pin the three views' semantics: messages = flat rows
# (id + corr_id, no raw_sip), errors = only 4xx/5xx, calls = one grouped
# row per corr_id with a message count.
class DataTable::Hep3SourceTest < ActiveSupport::TestCase
  fixtures :orgs, :islands

  setup do
    @island = islands(:alpha)
    @scope = "fsw"
    @name = "hep3-api"
    @src = DataTable::Hep3Source.new(island: @island, scope: @scope, name: @name)
  end

  def insert(call_id:, x_cid: "", meth: "INVITE", code: 0, ts: "2026-06-30 10:00:00.000000", raw: "X sip:y")
    payload = {ts: ts, call_id: call_id, x_cid: x_cid, method: meth, response_code: code, raw_sip: raw}.to_json
    HepMessage.bulk_insert([{tenant_id: @island.id, scope: @scope, name: @name, payload: payload}])
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
    assert_nil DataTable::Hep3Source.from_params(island: @island, params: {scope: "fsw"})
    assert DataTable::Hep3Source.from_params(island: @island, params: {scope: "fsw", name: "hep3-api"})
  end
end
