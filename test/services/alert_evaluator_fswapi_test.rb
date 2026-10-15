# frozen_string_literal: true

require "test_helper"

# AlertEvaluator over the FreeSWITCH kinds. They read the overview samples
# FswapiSyncServerJob writes (source "fswapi"): fs_calls / fs_idle_cpu are
# plain thresholds; fs_down reads fs_up (0 when the plugin answered 502).
class AlertEvaluatorFswapiTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  NOW = Time.utc(2026, 6, 9, 12, 0, 0)

  setup do
    MetricSample.delete_all
    @server = servers(:alpha)

    System.create!(
      server: @server,
      payload: {host: {}, plugins: [{"name" => "fswapi", "aliases" => []}]}.to_json,
      synced_at: Time.current
    )

    travel_to NOW
  end

  teardown do
    travel_back
    MetricSample.delete_all
  end

  def rule(metric_kind, threshold: 1, comparator: "gte", duration: 120)
    @server.alert_rules.create!(
      name: metric_kind, metric_kind: metric_kind, target_kind: "host",
      comparator: comparator, threshold: threshold, duration_seconds: duration
    )
  end

  # One sample per 15s bucket over the last ~3 minutes, like the sync job.
  def seed(from: NOW.to_i - 165, to: NOW.to_i - 15, **payload)
    (from..to).step(15) do |epoch|
      ts = Time.at(epoch).utc.iso8601

      MetricSample.insert!({server_id: @server.id, source: "fswapi", ts_iso: ts,
                            payload: payload.merge(ts: ts, source: "fswapi").to_json})
    end
  end

  test "active calls ≥ N fires when the whole window breaches" do
    r = rule("fs_calls", threshold: 100)
    seed(fs_up: 1, fs_calls: 157)

    AlertsLive.stub(:broadcast, nil) { AlertEvaluator.run(@server) }

    assert r.reload.firing
    assert_equal 157.0, r.last_value
    assert_equal "FreeSWITCH #{@server.name}", r.alert_events.sole.target_label
  end

  test "idle CPU ≤ X fires on a busy FreeSWITCH" do
    r = rule("fs_idle_cpu", threshold: 20, comparator: "lte")
    seed(fs_up: 1, fs_idle_cpu: 13.0)

    AlertsLive.stub(:broadcast, nil) { AlertEvaluator.run(@server) }

    assert r.reload.firing
  end

  test "FreeSWITCH down fires on recorded fs_up 0, and resolves when it answers again" do
    r = rule("fs_down")
    seed(fs_up: 0)

    AlertsLive.stub(:broadcast, nil) { AlertEvaluator.run(@server) }

    assert r.reload.firing
    assert_equal "down", r.format_value(r.last_value)

    travel 60.seconds
    seed(from: NOW.to_i, to: NOW.to_i + 45, fs_up: 1, fs_calls: 3)

    AlertsLive.stub(:broadcast, nil) { AlertEvaluator.run(@server) }

    assert_not r.reload.firing
  end

  test "no samples at all (controller unreachable) is no data, never down" do
    r = rule("fs_down")

    AlertsLive.stub(:broadcast, nil) { AlertEvaluator.run(@server) }

    assert_not r.reload.firing
    assert_equal "no_data", r.last_status
  end
end
