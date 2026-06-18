# frozen_string_literal: true

# MetricsWarehouse — local SQLite query layer that returns the SAME
# envelope as Voodu::Client#metrics (`/api/pat/v1/metrics`), but
# served from the MetricSample warehouse instead of round-tripping
# the controller.
#
# Wired in via MetricsData#fetch: when ENV["WAREHOUSE"]=true,
# fetch routes through here. Drop-in replacement — the chart code
# below (formatters, latest cache, points_for, latest_for) sees an
# identical Hash and doesn't care which path produced it.
#
# Why mirror the controller's envelope exactly (and not invent a
# leaner shape)?
#
#   - Zero churn in the read pipeline: MetricsData stays unaware.
#   - Feature-flag rollback is one ENV var, no schema drift.
#   - Side-by-side A/B comparison is exact bytes vs exact bytes.
#
# Bucket aggregation is the same algorithm the controller does
# (avg per fixed-width bucket, ≤300 buckets per query). The
# autoInterval rounding is mirrored from handlers_metrics.go so a
# `range=24h` query produces the SAME 5-min buckets either way.
class MetricsWarehouse
  # Allow-list — mirrors metricExtractors in
  # internal/metrics/reader.go on the controller side. Two reasons
  # to keep this list local:
  #
  #   1. SQL injection guard. The metric name is INTERPOLATED into
  #      json_extract(payload, '$.X') because SQLite doesn't bind
  #      JSON path expressions. Allow-list ensures only known-safe
  #      identifiers reach the SQL string.
  #   2. Honest error when an operator typos a metric name.
  #
  # Drift risk: if the controller adds a new metric and this list
  # isn't updated, the WebUI silently won't graph it. Acceptable
  # because (a) new metrics arrive rarely, (b) adding here is a
  # 1-line change. Document the dependency in the commit that adds
  # a new metric upstream.
  ALLOWED_METRICS = %w[
    cpu_percent
    mem_used_bytes mem_total_bytes
    disk_used_bytes disk_total_bytes
    mem_usage_bytes mem_limit_bytes
    net_rx_bytes net_tx_bytes
    net_rx_delta_bytes net_tx_delta_bytes
    block_read_bytes block_write_bytes
    block_read_delta_bytes block_write_delta_bytes

    req_count req_2xx req_3xx req_4xx req_5xx
    latency_p50_ms latency_p90_ms latency_p95_ms latency_p99_ms latency_max_ms
    bytes_out
  ].freeze

  # Friendly range aliases (mirror rangeAliases in handlers_metrics.go).
  # Falls back to integer seconds for tests / unusual calls.
  RANGE_ALIASES = {
    "15m" => 15 * 60,
    "30m" => 30 * 60,
    "1h" => 60 * 60,
    "3h" => 3 * 60 * 60,
    "6h" => 6 * 60 * 60,
    "12h" => 12 * 60 * 60,
    "24h" => 24 * 60 * 60,
    "3d" => 3 * 24 * 60 * 60,
    "7d" => 7 * 24 * 60 * 60
  }.freeze

  # Bucket-size steps. Operator-selectable via the /metrics interval
  # picker. 1s/10s/30m are opt-in zoom levels — useful when the
  # operator KNOWS the data is dense enough to fill them (e.g. a
  # busy ingress at 1s buckets surfaces per-second spikes hidden by
  # the default 15s sampling cadence).
  INTERVAL_ALIASES = {
    "1s" => 1,
    "10s" => 10,
    "15s" => 15,
    "30s" => 30,
    "1m" => 60,
    "5m" => 300,
    "15m" => 900,
    "30m" => 1800,
    "1h" => 3600
  }.freeze

  # autopick steps — what `interval=auto` resolves to. INTENTIONALLY
  # narrower than INTERVAL_ALIASES: floor at 15s so auto-mode doesn't
  # land on 1s/10s where 90% of buckets would be empty (sampler ticks
  # every 15s, so sub-15s buckets are mostly dishonest unless the
  # operator explicitly opts in via the picker).
  INTERVAL_STEPS = [15, 30, 60, 300, 900, 1800, 3600].freeze

  # Caps chart length — matches MaxBuckets in internal/metrics/reader.go.
  # 300 is the SVG sparkline sweet spot.
  MAX_BUCKETS = 300

  # Per-metric bucket aggregation function. Default is AVG (smooths
  # the line, shows "typical" value); MAX preserves brief spikes.
  #
  # Why per-metric: spike behaviour is metric-dependent.
  #
  #   - cpu_percent: spike-sensitive. A 5s burst to 100% across a
  #     5min bucket gets diluted by AVG to ~3% — operator can't see
  #     the saturation that just happened. MAX keeps the peak.
  #   - net_*_delta_bytes / block_*_delta_bytes: same shape — these
  #     are per-tick deltas (15s window), so they're inherently
  #     spike-shaped. AVG would hide bursts; MAX surfaces them.
  #   - mem_*_bytes / disk_*_bytes / cumulative *_bytes: slow-
  #     changing values. AVG and MAX produce nearly identical lines
  #     on these (consecutive samples are basically the same), so
  #     AVG is safe and a touch smoother visually.
  #
  # Matches what Grafana / Datadog default to for the equivalent
  # metric families.
  METRIC_AGGREGATIONS = {
    "cpu_percent" => "MAX",
    "net_rx_delta_bytes" => "MAX",
    "net_tx_delta_bytes" => "MAX",
    "block_read_delta_bytes" => "MAX",
    "block_write_delta_bytes" => "MAX",

    # Ingress counters — SUM across buckets so a "last 1h" chart
    # shows TOTAL requests in each render-bucket, not the avg per
    # 15s window. Operator math: total req over visible range =
    # sum of every chart point.
    "req_count" => "SUM",
    "req_2xx" => "SUM",
    "req_3xx" => "SUM",
    "req_4xx" => "SUM",
    "req_5xx" => "SUM",
    "bytes_out" => "SUM",

    # Ingress latency percentiles — MAX preserves the worst spike
    # across each render-bucket. p99 of a 5-minute chart-bucket =
    # max of the 20 underlying 15s-bucket p99 values. Same family
    # rule as CPU: peaks matter, averages hide them.
    "latency_p50_ms" => "MAX",
    "latency_p90_ms" => "MAX",
    "latency_p95_ms" => "MAX",
    "latency_p99_ms" => "MAX",
    "latency_max_ms" => "MAX"
  }.freeze
  DEFAULT_AGGREGATION = "AVG"

  # query — class entry point matching the controller's handler
  # signature. Returns the JSON envelope (stringified keys) that
  # Voodu::Client#metrics would have returned, ready to flow through
  # MetricsData unchanged.
  def self.query(island, source:, metric:, range:, interval:, scope: nil, name: nil, pod: nil)
    new(island).query(
      source: source, metric: metric, range: range, interval: interval,
      scope: scope, name: name, pod: pod
    )
  end

  def initialize(island)
    @island = island
  end

  def query(source:, metric:, range:, interval:, scope:, name:, pod:)
    raise ArgumentError, "unknown metric #{metric.inspect}" unless ALLOWED_METRICS.include?(metric)

    range_s = resolve_range(range)
    interval_s = resolve_interval(interval, range_s)
    end_t = Time.current
    start_t = end_t - range_s

    base = scoped_relation(source, scope, name, pod, metric, start_t.to_i, end_t.to_i)

    {
      "metric" => metric,
      "interval_seconds" => interval_s,
      "available_from" => available_from_iso(source),
      "truncated" => truncated?(source, start_t),
      "series" => build_series(base, metric, interval_s),
      "latest" => build_latest(base, metric)
    }
  end

  private

  # scoped_relation — builds the AR relation with ALL filter clauses
  # applied via AR's `.where` (bind params resolved by AR, never
  # raw `?` placeholders). Reused by series + latest so they walk
  # IDENTICAL row sets.
  #
  # Why AR `.where` instead of raw `connection.exec_query`? Earlier
  # we used exec_query with a positional binds Array. Rails 8.1's
  # SQLite3 adapter doesn't apply raw-value binds the same way —
  # the `?` placeholders ended up un-substituted in some paths,
  # causing WHERE to filter out every row. AR `.where` goes through
  # the prepared-statement path and binds reliably.
  #
  # `metric_present` is the only raw fragment (json_extract uses a
  # path expression SQLite can't bind). `metric` is allow-listed at
  # the entry of query(), so the interpolation is safe.
  def scoped_relation(source, scope, name, pod, metric, start_ts, end_ts)
    rel = MetricSample
      .where(tenant_id: @island.id, source: source.to_s)
      .where(ts_epoch: start_ts...end_ts)
      .where(metric_present_sql(metric))

    rel = rel.where(scope: scope) if scope.present?
    rel = rel.where(name: name) if name.present?
    rel = rel.where(pod: pod) if pod.present?
    rel
  end

  # build_series — bucket aggregation via AR's pluck. The
  # `(ts_epoch / N) * N` floor-to-bucket arithmetic stays inline
  # (Arel.sql wrapper required since Rails 8 to assert "we know
  # this is safe SQL, not user input"). N comes from interval_s
  # which is allow-listed via INTERVAL_STEPS — never operator input.
  def build_series(rel, metric, interval_s)
    bucket = Arel.sql("(ts_epoch / #{interval_s}) * #{interval_s}")
    agg_fn = METRIC_AGGREGATIONS.fetch(metric, DEFAULT_AGGREGATION)
    agg_expr = Arel.sql("#{agg_fn}(CAST(json_extract(payload, '$.#{metric}') AS REAL))")

    rows = rel.group(bucket).order(bucket).pluck(bucket, agg_expr)

    rows.map do |bucket_epoch, val|
      {"ts" => Time.at(bucket_epoch.to_i).utc.iso8601, "value" => val.to_f}
    end
  end

  # build_latest — single most recent unaggregated sample. Matches
  # the controller's `Latest` field semantics (stable across range
  # pills). nil when the filtered window has no rows.
  def build_latest(rel, metric)
    row = rel.order(ts_epoch: :desc)
      .limit(1)
      .pluck(:ts_iso, Arel.sql(metric_real_sql(metric)))
      .first
    return nil unless row

    {"ts" => row[0], "value" => row[1].to_f}
  end

  # truncated? — true when the warehouse's oldest sample for this
  # tenant + source is NEWER than the query start. Mirrors the
  # controller's `available_from > start` truncation flag. Lets the
  # WebUI render an honest "partial range" hint instead of a chart
  # that looks complete but only goes back N days.
  def truncated?(source, start_t)
    earliest = MetricSample.where(tenant_id: @island.id, source: source.to_s)
      .minimum(:ts_epoch)
    earliest.present? && earliest > start_t.to_i
  end

  # available_from_iso — earliest ts in the warehouse for this
  # tenant + source. Hits idx_metric_samples_watermark partial fan
  # (well, the source-scoped equivalent). Cheap.
  def available_from_iso(source)
    earliest = MetricSample.where(tenant_id: @island.id, source: source.to_s)
      .minimum(:ts_epoch)
    earliest && Time.at(earliest).utc.iso8601
  end

  # ── SQL fragment helpers ────────────────────────────────────────
  #
  # Metric name is interpolated into JSON path — validated by the
  # ALLOWED_METRICS allow-list at the top of `query`. Never reached
  # with operator input.

  def metric_present_sql(metric)
    "json_extract(payload, '$.#{metric}') IS NOT NULL"
  end

  def metric_real_sql(metric)
    "CAST(json_extract(payload, '$.#{metric}') AS REAL)"
  end

  def bucket_sql(interval_s)
    "(ts_epoch / #{interval_s}) * #{interval_s}"
  end

  # ── Range + interval parsing (mirror Go controller) ────────────
  #
  # Go's time.ParseDuration handles "5m", "90s", "2h", "3d" natively.
  # Ruby's String#to_i takes only the LEADING integer and discards
  # the unit suffix — so "5m".to_i is 5 (seconds), not 300. That
  # silently turned every 5m chart into a 5-second window query,
  # producing empty series. Fix: parse Go-style duration suffixes
  # explicitly before falling back to the (still useful) pure-int
  # path for tests that pass raw seconds.
  GO_DURATION = /\A(\d+)([smhd])\z/
  UNIT_SECONDS = {"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}.freeze

  def resolve_range(raw)
    s = raw.to_s.strip
    return RANGE_ALIASES[s] if RANGE_ALIASES.key?(s)

    if (m = s.match(GO_DURATION))
      n = m[1].to_i
      return n * UNIT_SECONDS[m[2]] if n.positive?
    end

    n = s.to_i
    return n if n.positive?

    3600 # 1h default — same as controller
  end

  def resolve_interval(raw, range_s)
    s = raw.to_s.strip
    return autopick(range_s) if s.empty? || s == "auto"
    return INTERVAL_ALIASES[s] if INTERVAL_ALIASES.key?(s)

    if (m = s.match(GO_DURATION))
      n = m[1].to_i
      return n * UNIT_SECONDS[m[2]] if n.positive?
    end

    n = s.to_i
    return n if n.positive?

    autopick(range_s)
  end

  # autopick — naive = range/MAX_BUCKETS, rounded UP to the next
  # clean step. Identical algorithm to autoInterval() in
  # handlers_metrics.go so both paths produce the same X-axis
  # density for any given range.
  def autopick(range_s)
    naive = (range_s.to_f / MAX_BUCKETS).ceil
    return 15 if naive <= 0

    INTERVAL_STEPS.find { |step| step >= naive } || 3600
  end
end
