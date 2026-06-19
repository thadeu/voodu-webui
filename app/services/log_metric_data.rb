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
  def initialize(island, query:, range:, interval: "auto", scope: nil, name: nil, from: nil, until_: nil)
    @island = island
    @query = query.to_s
    @range = range.to_s
    @interval = interval.to_s.presence || "auto"
    @scope = scope.to_s
    @name = name.to_s
    @from = from
    @until_ = until_
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

  # clamped? — the requested window reaches before the log retention floor, so
  # the series only covers the last RETENTION_DAYS rather than the full span.
  # Custom mode: clamped when `from` predates the floor; relative: when the
  # range width exceeds retention.
  def clamped?
    floor_ms = LogTail::FilePath::RETENTION_DAYS.days.to_i * 1000

    if custom?
      f = Time.zone.parse(@from.to_s)
      f.present? && f < LogTail::FilePath::RETENTION_DAYS.days.ago
    else
      MetricsPageData.range_to_ms(@range) > floor_ms
    end
  rescue ArgumentError, TypeError
    false
  end

  private

  def custom?
    @from.present? && @until_.present?
  end

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

    # Headline reduces the RAW (sparse) buckets; the sparkline gets the
    # zero-filled series so empty intervals read as a flat 0 instead of a
    # hole (the warehouse only emits buckets that had matches).
    {value: headline, formatted: fmt(headline), series: densify(points)}
  rescue => e
    Rails.logger.warn("log-metric read failed def=#{def_key}: #{e.class} #{e.message}")
    {value: 0, formatted: "0", series: []}
  end

  # series_points — the per-bucket count series from the warehouse, bucketed by
  # the dashboard interval. Empty until the counter first tracks this def.
  def series_points
    env = MetricsWarehouse.query(
      @island, source: "log", metric: "log_count",
      range: @range, interval: @interval, scope: nil, name: def_key, pod: nil,
      from: @from, until_: @until_
    )

    @interval_seconds = env["interval_seconds"].to_i

    Array(env["series"]).map do |p|
      v = p["value"].to_f

      {ts: p["ts"], value: v, formatted: fmt(v)}
    end
  end

  # densify — a count series is sparse (the warehouse only writes buckets that
  # had ≥1 match), so the sparkline draws holes/clusters instead of a trend.
  # Rebuild a dense series across the WHOLE window (one bucket per interval
  # step from window start → end), carrying the real counts and filling 0
  # everywhere else, so the sparkline reads as a flat 0 baseline with spikes
  # spanning the full range (like the metric charts). Headline still reduces
  # the raw buckets, so the numbers don't change.
  def densify(points)
    # No matches ever → leave it empty so the card shows a clean number with
    # NO sparkline (rather than a flat zero line for a panel with no data).
    return points if points.empty?

    step = @interval_seconds.to_i
    start_b, end_b = window_buckets(step)
    return points if step <= 0 || start_b.nil? || end_b.nil? || end_b <= start_b

    by_bucket = {}
    points.each do |p|
      b = bucket_epoch(p[:ts], step)
      by_bucket[b] = p[:value] if b
    end

    out = []
    b = start_b
    while b <= end_b && out.size < 6_000
      v = by_bucket.fetch(b, 0.0)
      out << {ts: Time.at(b).utc.iso8601, value: v, formatted: fmt(v)}
      b += step
    end

    out
  end

  # window_buckets — [start_bucket, end_bucket] epochs aligned to the interval
  # step, covering the dashboard's window (relative range, or the custom span).
  def window_buckets(step)
    return [nil, nil] if step <= 0

    end_t = custom? ? Time.zone.parse(@until_.to_s).to_i : Time.current.to_i
    span = if custom?
      end_t - Time.zone.parse(@from.to_s).to_i
    else
      MetricsPageData.range_to_ms(@range) / 1000
    end

    [((end_t - span) / step) * step, (end_t / step) * step]
  rescue ArgumentError, TypeError
    [nil, nil]
  end

  def bucket_epoch(iso, step)
    t = Time.zone.parse(iso.to_s)
    t && (t.to_i / step) * step
  rescue ArgumentError, TypeError
    nil
  end

  # fmt — whole numbers as delimited integers ("1,284"); fractional (avg) keeps
  # up to 2 decimals ("2.5").
  def fmt(number)
    n = number.to_f
    rounded = (n == n.round) ? n.round : n.round(2)

    ActiveSupport::NumberHelper.number_to_delimited(rounded)
  end
end
