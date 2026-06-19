# frozen_string_literal: true

require "test_helper"

# Focused on the custom-window resolution (the metrics range "custom" mode):
# explicit from/until_ pin an absolute window; without them the query falls
# back to `range` relative to now.
class MetricsWarehouseTest < ActiveSupport::TestCase
  fixtures :islands

  setup do
    @island = islands(:alpha)
    @base = Time.zone.local(2026, 6, 19, 12, 0, 0)
    MetricSample.where(tenant_id: @island.id).delete_all
  end

  teardown { MetricSample.where(tenant_id: @island.id).delete_all }

  test "from/until_ pin an absolute window, excluding samples outside it" do
    seed(@base - 2.hours, 10)    # before from
    seed(@base, 50)              # inside
    seed(@base + 5.minutes, 60)  # inside
    seed(@base + 2.hours, 99)    # after until

    env = MetricsWarehouse.query(
      @island, source: "system", metric: "cpu_percent",
      range: "1h", interval: "1m",
      from: @base - 1.minute, until_: @base + 10.minutes
    )

    values = env["series"].map { |p| p["value"] }

    assert_includes values, 50.0
    assert_includes values, 60.0
    assert_not_includes values, 10.0, "before the window"
    assert_not_includes values, 99.0, "after the window"
  end

  test "without from/until_, falls back to range relative to now" do
    travel_to @base

    seed(@base - 30.minutes, 42) # within last 1h
    seed(@base - 3.hours, 7)     # outside last 1h

    env = MetricsWarehouse.query(@island, source: "system", metric: "cpu_percent", range: "1h", interval: "1m")
    values = env["series"].map { |p| p["value"] }

    assert_includes values, 42.0
    assert_not_includes values, 7.0
  ensure
    travel_back
  end

  test "an invalid/half custom window (only from) falls back to range" do
    travel_to @base
    seed(@base - 10.minutes, 21)

    env = MetricsWarehouse.query(@island, source: "system", metric: "cpu_percent",
      range: "1h", interval: "1m", from: @base - 5.minutes, until_: nil)

    assert_includes env["series"].map { |p| p["value"] }, 21.0, "half window → range fallback (last 1h)"
  ensure
    travel_back
  end

  private

  def seed(time, cpu)
    iso = time.utc.iso8601

    MetricSample.bulk_insert([{
      tenant_id: @island.id, source: "system", ts_iso: iso,
      payload: {source: "system", ts: iso, name: "host", cpu_percent: cpu}.to_json
    }])
  end
end
