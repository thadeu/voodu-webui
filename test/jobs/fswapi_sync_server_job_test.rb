# frozen_string_literal: true

require "test_helper"

# FswapiSyncServerJob turns one /overview reply into one warehouse sample — the
# FreeSWITCH history — and writes nothing when FreeSWITCH cannot answer.
class FswapiSyncServerJobTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  # FakeFswapi stands in for Voodu::Client: one canned /overview reply, or the
  # error the controller proxy would raise.
  class FakeFswapi
    attr_reader :routes

    def initialize(reply: nil, error: nil)
      @reply = reply
      @error = error
      @routes = []
    end

    def fswapi(route, _params = nil)
      @routes << route

      raise @error if @error

      @reply
    end
  end

  OVERVIEW = {
    "calls" => 3, "channels" => 6,
    "status" => {"up" => true, "version" => "1.10.11", "sessions" => 6, "sessions_peak" => 9,
                 "sessions_per_sec" => 1, "idle_cpu" => 97.1}
  }.freeze

  setup { @server = servers(:alpha) }

  test "writes one fswapi sample with the overview gauges" do
    now = Time.utc(2026, 10, 14, 12, 0, 0)
    fake = FakeFswapi.new(reply: OVERVIEW)

    FswapiSyncServerJob.new.sync(@server, fake, now: now)

    assert_equal ["overview"], fake.routes

    sample = MetricSample.where(server_id: @server.id, source: "fswapi").sole
    payload = JSON.parse(sample.payload)

    assert_equal "2026-10-14T12:00:00Z", sample.ts_iso
    assert_equal 3, payload["fs_calls"]
    assert_equal 6, payload["fs_channels"]
    assert_equal 9, payload["fs_sessions_peak"]
    assert_in_delta 97.1, payload["fs_idle_cpu"]
    assert payload["up"]
    assert_equal 1, payload["fs_up"]
  end

  test "FreeSWITCH down (502) records fs_up 0 alone — gauges get a gap, not a zero" do
    error = Voodu::Client::ServerError.new("esl: authentication failed — set the event_socket password")

    FswapiSyncServerJob.new.sync(@server, FakeFswapi.new(error: error))

    payload = JSON.parse(MetricSample.where(source: "fswapi").sole.payload)

    assert_equal 0, payload["fs_up"]
    assert_nil payload["fs_calls"], "a zero would read as 'no calls'"
  end

  test "a controller the WebUI cannot reach records nothing — no data, not 'down'" do
    assert_nil FswapiSyncServerJob.new.sync(@server, FakeFswapi.new(error: Voodu::Client::TransportError.new("timeout")))
    assert_equal 0, MetricSample.where(source: "fswapi").count
  end

  test "the warehouse serves the sample as a series" do
    FswapiSyncServerJob.new.sync(@server, FakeFswapi.new(reply: OVERVIEW), now: 1.minute.ago)

    result = MetricsWarehouse.query(@server, source: "fswapi", metric: "fs_calls", range: "1h", interval: "auto")

    assert_equal 3.0, result["latest"]["value"]
    assert_equal [3.0], result["series"].map { |p| p["value"] }
  end
end
