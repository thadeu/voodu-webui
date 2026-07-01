# frozen_string_literal: true

require "test_helper"

# DatatableController#rows is the rows feed Table panels pull from. Pins
# the JSON contract (rows + fields + default_fields), the view switch
# (errors filters to 4xx/5xx), raw_sip exclusion, and the 404 for an
# unknown source.
class DatatableControllerTest < ActionDispatch::IntegrationTest
  fixtures :islands

  setup do
    @island = islands(:alpha)
    @key = @island.key
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1"

    HepMessage.bulk_insert([
      row(call_id: "c1", meth: "INVITE", code: 0, ts: "2026-06-30 10:00:01.000000"),
      row(call_id: "c1", meth: "", code: 200, ts: "2026-06-30 10:00:02.000000"),
      row(call_id: "c2", meth: "", code: 486, ts: "2026-06-30 10:00:03.000000")
    ])
  end

  teardown { ENV["WAREHOUSE"] = @prev_wh }

  def row(call_id:, meth:, code:, ts:)
    payload = {ts: ts, call_id: call_id, x_cid: "", method: meth, response_code: code, from_user: "a", raw_sip: "RAW #{call_id}"}.to_json
    {tenant_id: @island.id, scope: "fsw", name: "hep3-api", payload: payload}
  end

  test "returns rows + fields + default_fields for the messages view" do
    get metrics_datatable_rows_path(tenant_key: @key, source: "hep3", scope: "fsw", name: "hep3-api", view: "messages")

    assert_response :success
    body = JSON.parse(@response.body)

    assert_equal 3, body["rows"].size
    assert_includes body["fields"], "method"
    assert_includes body["default_fields"], "ts"
    assert_not body["rows"].first.key?("raw_sip"), "raw_sip stays out of the rows feed"
  end

  test "the errors view filters to 4xx/5xx" do
    get metrics_datatable_rows_path(tenant_key: @key, source: "hep3", scope: "fsw", name: "hep3-api", view: "errors")

    assert_response :success
    codes = JSON.parse(@response.body)["rows"].map { |r| r["response_code"] }

    assert_equal [486], codes
  end

  test "a DSL filter query narrows the rows" do
    get metrics_datatable_rows_path(tenant_key: @key, source: "hep3", scope: "fsw", name: "hep3-api",
      view: "messages", filter_query: "@method like /INVITE/")

    assert_response :success
    methods = JSON.parse(@response.body)["rows"].map { |r| r["method"] }

    assert_equal ["INVITE"], methods
  end

  test "a leading `filter` keyword is accepted (LogQuery parity)" do
    get metrics_datatable_rows_path(tenant_key: @key, source: "hep3", scope: "fsw", name: "hep3-api",
      view: "messages", filter_query: "filter @method like /INVITE/")

    assert_response :success
    methods = JSON.parse(@response.body)["rows"].map { |r| r["method"] }

    assert_equal ["INVITE"], methods
  end

  test "an unparseable filter returns 422 + the error, NOT unfiltered rows" do
    get metrics_datatable_rows_path(tenant_key: @key, source: "hep3", scope: "fsw", name: "hep3-api",
      view: "messages", filter_query: "@method like")

    assert_response :unprocessable_entity
    body = JSON.parse(@response.body)

    assert_empty body["rows"], "a broken filter must hold rows back, never show everything"
    assert body["error"].present?, "the parse message is surfaced for the operator"
  end

  test "the range window scopes rows to the page's time span (charts + table in lockstep)" do
    now = Time.now.utc
    HepMessage.bulk_insert([
      at(now - 300, "recent"),
      at(now - (3 * 3600), "old")
    ])

    get metrics_datatable_rows_path(tenant_key: @key, source: "hep3", scope: "fsw", name: "hep3-api",
      view: "messages", range: "1h")

    assert_response :success
    froms = JSON.parse(@response.body)["rows"].map { |r| r["from_user"] }

    assert_includes froms, "recent", "a message inside the last hour shows"
    assert_not_includes froms, "old", "a message 3h ago is outside a 1h window — hidden"
  end

  # at — a message stamped `seconds_ago` relative to now, tagged via from_user.
  def at(time, from_user)
    ts = time.strftime("%Y-%m-%d %H:%M:%S.%6N")
    payload = {ts: ts, call_id: "w", x_cid: "", method: "INVITE", response_code: 0, from_user: from_user}.to_json
    {tenant_id: @island.id, scope: "fsw", name: "hep3-api", payload: payload}
  end

  test "404 for an unknown source" do
    get metrics_datatable_rows_path(tenant_key: @key, source: "nope", scope: "x", name: "y")

    assert_response :not_found
  end
end
