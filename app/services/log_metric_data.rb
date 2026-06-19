# frozen_string_literal: true

# LogMetricData — the READ side of a dashboard log-count panel. The counter
# (LogMetricsSyncIslandJob) pre-aggregates the per-bucket MATCH COUNT of a
# filter into the warehouse (source="log", metric="log_count", name=<def_key>).
# This reads that count series at the dashboard's interval and reduces it to
# the headline number per the query's `| agg` suffix:
#
#   count → the LATEST bucket  (the current value / rate "right now")
#   sum   → the SUM of buckets (cumulative total over the range)
#   avg   → the MEAN of buckets
#   min   → the smallest bucket
#   max   → the largest bucket
#
# The sparkline is always the per-bucket count series, grouped by the chosen
# interval (1m vs 10s give genuinely different bucketing).
#
# def_key MUST match LogMetric::Definition.key_for — the write/read contract.
class LogMetricData
  # @param island   [Island]
  # @param query    [String] LogQuery filter, optionally with a `| agg` suffix
  # @param range    [String] dashboard range key (MetricsPageData::RANGES)
  # @param interval [String] dashboard interval (MetricsPageData::INTERVALS) —
  #   what the count series is bucketed by (defaults to "auto")
  # @param scope    [String] workload scope (for the def_key)
  # @param name     [String] workload resource name (for the def_key)
  def initialize(island, query:, range:, interval: "auto", scope: nil, name: nil)
    @island = island
    @query = query.to_s
    @range = range.to_s
    @interval = interval.to_s.presence || "auto"
    @scope = scope.to_s
    @name = name.to_s
  end

  def value
    data[:value]
  end

  def formatted
    data[:formatted]
  end

  # series — [{ts:, value:, formatted:}] per bucket, for the sparkline.
  def series
    data[:series]
  end

  # meta — a muted qualifier for the card ("avg" / "min" / "max" / "sum"), nil
  # for count (the default needs no label).
  def meta
    (agg == :count) ? nil : agg.to_s
  end

  # clamped? — the dashboard range reaches past the log retention floor, so the
  # series only covers the last RETENTION rather than the full requested span.
  def clamped?
    MetricsPageData.range_to_ms(@range) > (LogTail::FilePath::RETENTION_DAYS.days.to_i * 1000)
  end

  private

  def agg
    @agg ||= LogQuery.compile(@query).agg || :count
  end

  def def_key
    @def_key ||= LogMetric::Definition.key_for(scope: @scope, name: @name, query: @query)
  end

  def data
    @data ||= build
  end

  def build
    points = series_points
    values = points.map { |p| p[:value] }

    headline = case agg
    when :count then values.last || 0          # latest bucket = current value
    when :avg then values.empty? ? 0 : (values.sum / values.size)
    when :min then values.min || 0
    when :max then values.max || 0
    else values.sum                            # :sum → cumulative total
    end

    {value: headline, formatted: fmt(headline), series: points}
  rescue => e
    Rails.logger.warn("log-metric read failed def=#{def_key}: #{e.class} #{e.message}")
    {value: 0, formatted: "0", series: []}
  end

  # series_points — the per-bucket count series from the warehouse, bucketed by
  # the dashboard interval. Empty until the counter first tracks this def.
  def series_points
    env = MetricsWarehouse.query(
      @island, source: "log", metric: "log_count",
      range: @range, interval: @interval, scope: nil, name: def_key, pod: nil
    )

    Array(env["series"]).map do |p|
      v = p["value"].to_f

      {ts: p["ts"], value: v, formatted: fmt(v)}
    end
  end

  # fmt — whole numbers as delimited integers ("1,284"); fractional (avg) keeps
  # up to 2 decimals ("2.5").
  def fmt(number)
    n = number.to_f
    rounded = (n == n.round) ? n.round : n.round(2)

    ActiveSupport::NumberHelper.number_to_delimited(rounded)
  end
end
