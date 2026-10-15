# frozen_string_literal: true

require "test_helper"

# The poller's restart watermark only counts the sources the poller writes.
# Rows the WebUI writes "now" (log counts, the FreeSWITCH overview) must not
# move it, or the next poller restart skips controller samples — a gap.
class MetricSampleWatermarkTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  def sample(server, source, ts)
    MetricSample.bulk_insert([{server_id: server.id, source: source, ts_iso: ts.utc.iso8601,
                               payload: {source: source, ts: ts.utc.iso8601}.to_json}])
  end

  test "rows the WebUI writes do not move the watermark" do
    server = servers(:alpha)
    pulled = Time.utc(2026, 10, 14, 12, 0, 0)

    sample(server, "system", pulled)
    sample(server, "pod", pulled - 30)
    sample(server, "log", pulled + 600)
    sample(server, "fswapi", pulled + 900)

    assert_equal pulled.to_i, MetricSample.last_ts_for(server)
  end

  test "the newest poller source wins" do
    server = servers(:alpha)
    newest = Time.utc(2026, 10, 14, 12, 5, 0)

    sample(server, "system", newest - 60)
    sample(server, "ingress", newest)

    assert_equal newest.to_i, MetricSample.last_ts_for(server)
  end

  test "only WebUI rows reads as an empty warehouse" do
    server = servers(:alpha)
    sample(server, "fswapi", Time.current)

    assert_equal 0, MetricSample.last_ts_for(server)
  end
end
