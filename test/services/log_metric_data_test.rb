# frozen_string_literal: true

require "test_helper"

# Exercises LogMetricData's READ reductions over a hand-seeded warehouse count
# series (source="log", metric="log_count", name=<def_key>). The counter writes
# the per-bucket match count; this asserts how the `| agg` suffix reduces that
# series to the headline: count=latest bucket, sum=total, avg=mean, min/max.
#
# Time is pinned just after the seeded buckets so they fall inside the range.
class LogMetricDataTest < ActiveSupport::TestCase
  fixtures :orgs, :islands

  setup do
    @island = islands(:alpha)
    @base = Time.zone.local(2026, 6, 9, 14, 47, 50)
    travel_to @base + 1.minute
    MetricSample.where(tenant_id: @island.id).delete_all
  end

  teardown { MetricSample.where(tenant_id: @island.id).delete_all }

  test "count → the latest bucket (the current value)" do
    q = "@message like /INVITE/ | count"
    seed(q, [[3, 5], [2, 2], [1, 9]]) # newest (1 min ago) = 9

    assert_equal 9, data(q).value
  end

  test "no agg suffix defaults to count" do
    q = "@message like /INVITE/"
    seed(q, [[3, 5], [1, 9]])

    assert_equal 9, data(q).value
  end

  test "sum → cumulative total of the buckets over the range" do
    q = "@message like /INVITE/ | sum"
    seed(q, [[3, 5], [2, 2], [1, 9]])

    assert_equal 16, data(q).value
  end

  test "avg → mean of the buckets" do
    q = "@message like /INVITE/ | avg"
    seed(q, [[3, 4], [1, 8]]) # mean 6

    assert_equal 6, data(q).value
  end

  test "min / max → smallest / largest bucket" do
    seed("@message like /INVITE/ | min", [[3, 5], [2, 2], [1, 9]])
    seed("@message like /INVITE/ | max", [[3, 5], [2, 2], [1, 9]])

    assert_equal 2, data("@message like /INVITE/ | min").value
    assert_equal 9, data("@message like /INVITE/ | max").value
  end

  test "exposes the per-bucket count series for the sparkline" do
    q = "@message like /INVITE/ | count"
    seed(q, [[3, 5], [2, 2], [1, 9]])

    points = data(q).series

    assert points.size >= 1
    assert_includes points.map { |p| p[:value] }, 9.0
  end

  test "the sparkline series zero-fills gaps between counts (no holes)" do
    q = "@message like /INVITE/ | sum"
    seed(q, [[5, 7], [1, 3]]) # buckets 5m + 1m ago — 3 empty minutes between

    d = data(q, interval: "1m")

    assert_equal 10, d.value, "headline reduces the RAW buckets (zeros don't change the sum)"

    values = d.series.map { |p| p[:value] }
    assert_operator d.series.size, :>=, 5, "the gap between the two counts is filled with zero buckets"
    assert_includes values, 0.0, "empty intervals read as 0, not a hole"
    assert_includes values, 7.0
    assert_includes values, 3.0
  end

  test "no samples yet → 0 (no fallback scan)" do
    assert_equal 0, data("@message like /INVITE/ | count").value
    assert_empty data("@message like /INVITE/ | count").series
  end

  test "meta shows the agg for non-count, nil for count" do
    assert_equal "avg", data("@message like /x/ | avg").meta
    assert_equal "max", data("@message like /x/ | max").meta
    assert_nil data("@message like /x/").meta
    assert_nil data("@message like /x/ | count").meta
  end

  # Regression guard for the shipped bug: the interval was hardcoded to "auto",
  # so 10s and 1m gave the same sparkline. A coarser interval must merge buckets
  # (SUM), which changes count's latest-bucket value.
  test "the interval is respected — coarser buckets merge, changing count(latest)" do
    q = "@message like /INVITE/ | count"
    seed(q, [[3, 2], [2, 5], [1, 3]]) # three distinct minute buckets

    assert_equal 3, data(q, interval: "1m").value, "1m → three buckets, latest = 3"
    assert_equal 10, data(q, interval: "1h").value, "1h → one merged bucket (SUM), latest = 2+5+3"

    assert_operator data(q, interval: "1m").series.size, :>, data(q, interval: "1h").series.size,
      "finer interval → more sparkline points"
  end

  test "clamped? only when the range outruns the log retention" do
    assert_not data("@message like /x/", range: "1h").clamped?
    assert data("@message like /x/", range: "30d").clamped?
  end

  test "formats whole numbers with delimiters; avg keeps decimals" do
    seed("@message like /a/ | sum", [[2, 1200], [1, 300]]) # 1500
    assert_equal "1,500", data("@message like /a/ | sum").formatted

    seed("@message like /b/ | avg", [[2, 3], [1, 4]]) # 3.5
    assert_equal "3.5", data("@message like /b/ | avg").formatted
  end

  private

  def data(query, range: "1h", interval: "auto")
    LogMetricData.new(@island, query: query, range: range, interval: interval, scope: "fs", name: "fs")
  end

  # seed — write per-bucket log_count samples under the query's def_key.
  # counts: [[minutes_ago, count], ...].
  def seed(query, counts)
    key = LogMetric::Definition.key_for(scope: "fs", name: "fs", query: query)

    rows = counts.map do |mins, n|
      iso = "#{(@base - mins.minutes).utc.iso8601[0, 16]}:00Z"

      {tenant_id: @island.id, source: "log", ts_iso: iso,
       payload: {source: "log", ts: iso, name: key, log_count: n}.to_json}
    end

    MetricSample.bulk_insert(rows)
  end
end
