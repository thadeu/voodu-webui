# frozen_string_literal: true

require "test_helper"

# DataTable::FswapiSource — FreeSWITCH as a dashboard source: live lists as
# table rows (through the plugin), history views as warehouse series.
class DataTable::FswapiSourceTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

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

  CALLS = {"rows" => [
    {"cid_num" => "5511999990000", "dest" => "0656%235521", "callstate" => "ACTIVE", "direction" => "inbound", "created_epoch" => "100"},
    {"cid_num" => "5521888880000", "dest" => "4000", "callstate" => "RINGING", "direction" => "inbound", "created_epoch" => "160"}
  ]}.freeze

  setup do
    @server = servers(:alpha)
    Rails.cache.clear
  end

  def source = DataTable::FswapiSource.new(server: @server)

  test "each view takes only the shapes it can draw" do
    assert_equal %w[table number area bars line gauge_radial gauge_linear], DataTable::FswapiSource.shapes_for("calls")
    assert_equal %w[table], DataTable::FswapiSource.shapes_for("gateways")
    assert_not_includes DataTable::FswapiSource.shapes_for("idle_cpu"), "table"
    assert_empty DataTable::FswapiSource.shapes_for("nope")
  end

  test "rows are the live list, formatted like the /fswapi page, with a stable position id" do
    rows = Voodu::Client.stub(:new, FakeFswapi.new(replies: {"calls" => CALLS})) do
      source.rows(view: "calls", now: Time.zone.at(220))
    end

    assert_equal [1, 2], rows.map { |r| r["id"] }
    assert_equal "2:00", rows.first["duration"]
    assert_equal "0656#5521", rows.first["to"], "%23 decoded"
    assert_equal %w[id duration from to b_leg state direction], rows.first.keys
  end

  test "the filter is plain text, like the page" do
    rows = Voodu::Client.stub(:new, FakeFswapi.new(replies: {"calls" => CALLS})) do
      source.rows(view: "calls", filter_query: "5521888")
    end

    assert_equal ["5521888880000"], rows.map { |r| r["from"] }
  end

  test "FreeSWITCH not answering raises FetchError with the plugin's message" do
    error = Voodu::Client::ServerError.new("esl: authentication failed — set the event_socket password")

    raised = assert_raises(DataTable::FswapiSource::FetchError) do
      Voodu::Client.stub(:new, FakeFswapi.new(error: error)) { source.rows(view: "calls") }
    end

    assert_includes raised.message, "event_socket password"
  end

  test "a history view reads the warehouse series" do
    ts = 2.minutes.ago.utc.iso8601
    MetricSample.bulk_insert([{server_id: @server.id, source: "fswapi", ts_iso: ts,
                               payload: {source: "fswapi", ts: ts, fs_up: 1, fs_idle_cpu: 83.5}.to_json}])

    points = source.series(view: "idle_cpu", range: "1h", interval: "auto")

    assert_equal 83.5, points.last[:value]
    assert_empty source.series(view: "gateways", range: "1h", interval: "auto"), "no history for a list-only view"
  end
end
