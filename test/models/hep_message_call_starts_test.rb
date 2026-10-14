# frozen_string_literal: true

require "test_helper"

# HepMessage.call_starts_series feeds the /hep3 count card. Pins: a call is
# counted ONCE, in the bucket of its first in-window message, even when its
# messages cross a bucket edge — so the buckets add up to the distinct calls.
class HepMessageCallStartsTest < ActiveSupport::TestCase
  SCOPE = "fsw"
  NAME = "hep3-api"

  def server = servers(:alpha)

  def insert(call_id, second, method: "INVITE", from_user: "alice")
    line = {
      ts: format("2026-06-30 10:00:%02d.000000", second), call_id: call_id, x_cid: "",
      method: method, response_code: 0, from_user: from_user
    }.to_json

    HepMessage.bulk_insert([{server_id: server.id, scope: SCOPE, name: NAME, payload: line}])
  end

  def series(bucket:, where_sql: nil, where_binds: [])
    base = HepMessage.minimum(:ts_epoch)
    from = (base / 60) * 60

    HepMessage.call_starts_series(
      server: server, scope: SCOPE, name: NAME, ts_from: from, ts_to: from + 60,
      bucket: bucket, where_sql: where_sql, where_binds: where_binds
    )
  end

  test "a call crossing a bucket edge is counted once, in the bucket it starts in" do
    insert("call-1", 8)
    insert("call-1", 12, method: "BYE")
    insert("call-2", 14)
    insert("call-3", 31)

    counts = series(bucket: 10).map(&:last)

    assert_equal [1, 1, 1], counts, "call-1 starts at :08, call-2 at :14, call-3 at :31"
    assert_equal 3, counts.sum, "the buckets add up to the distinct calls"
  end

  test "the filter narrows which calls count" do
    insert("call-1", 5, from_user: "alice")
    insert("call-2", 6, from_user: "bob")

    where_sql = "#{HepMessage.filter_expr("from_user")} LIKE ?"

    assert_equal 1, series(bucket: 60, where_sql: where_sql, where_binds: ["%bob%"]).sum(&:last)
  end

  test "calls ending in the same second keep distinct row ids, and the cursor pages past them" do
    insert("call-1", 10)
    insert("call-2", 10)
    insert("call-3", 10)

    source = DataTable::Hep3Source.new(server: server, scope: SCOPE, name: NAME)
    first = source.rows(view: "calls", limit: 2)
    rest = source.rows(view: "calls", limit: 2, before_id: first.last["id"])
    ids = (first + rest).map { |r| r["id"] }

    assert_equal 3, ids.uniq.size, "the DataTable dedups by id — equal ids would drop calls"
    assert_equal %w[call-1 call-2 call-3], (first + rest).map { |r| r["call_key"] }.sort
  end
end
