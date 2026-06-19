# frozen_string_literal: true

# LogMetricData — the READ side of a dashboard log-count panel. Returns the
# count (+ a history series for the sparkline) for a filter over the dashboard
# range. Two paths, transparently:
#
#   1. WAREHOUSE (Fase 2, normal): LogMetricsSyncIslandJob pre-aggregates
#      matches into MetricSample rows (source="log", metric="log_count",
#      name=<def_key>). We read that series with one cheap indexed query — no
#      file scan per render — and the total is the SUM over the range. This
#      gives history → a sparkline, and updates live on the counter's broadcast.
#
#   2. LIVE-SCAN FALLBACK (the original MVP): when the counter hasn't tracked
#      this def yet (brand-new panel, ≤ one sync tick old), we scan the NDJSON
#      warehouse directly so the card shows a real number immediately instead of
#      0. No history in this mode (sparkline hides until the warehouse fills).
#
# def_key MUST match LogMetric::Definition.key_for — it's the contract between
# the counter (write) and this reader.
class LogMetricData
  # ── live-scan fallback knobs (only used before the counter tracks a def) ──
  COUNT_CAP = 100_000
  CACHE_TTL = 20

  RETENTION = LogTail::FilePath::RETENTION_DAYS.days

  # @param island [Island]
  # @param query  [String] LogQuery filter
  # @param range  [String] dashboard range key (MetricsPageData::RANGES)
  # @param scope  [String] workload scope (for the def_key + warehouse read)
  # @param name   [String] workload resource name (for the def_key)
  # @param pods   [Array<String>] replica container names — fallback live-scan only
  def initialize(island, query:, range:, scope: nil, name: nil, pods: [])
    @island = island
    @query = query.to_s
    @range = range.to_s
    @scope = scope.to_s
    @name = name.to_s
    @pods = Array(pods).compact.map(&:to_s).reject(&:blank?)
  end

  # value — integer count over the range.
  def value
    data[:value]
  end

  # formatted — count with thousands separators ("1,284").
  def formatted
    ActiveSupport::NumberHelper.number_to_delimited(value)
  end

  # series — [{ts:, value:, formatted:}] for the sparkline. Empty in the
  # live-scan fallback (no history yet) → the card hides the sparkline.
  def series
    data[:series]
  end

  # truncated? — the count is a floor ("≥ value"). Only the live-scan cap can
  # trip this; the warehouse path serves the true tally.
  def truncated?
    data[:truncated]
  end

  # clamped? — the dashboard range reaches past the log retention floor, so the
  # count covers the last RETENTION rather than the full requested span.
  def clamped?
    data[:clamped]
  end

  private

  def data
    @data ||= warehouse_data || live_scan_data
  end

  # def_key — the warehouse `name` for this filter+workload. Same digest the
  # counter writes under.
  def def_key
    @def_key ||= LogMetric::Definition.key_for(scope: @scope, name: @name, query: @query)
  end

  # tracked? — has the counter ever written a sample for this def? Distinguishes
  # "counted, genuinely 0 in range" (trust the warehouse) from "never counted"
  # (fall back to a live scan). Indexed existence check, cheap.
  def tracked?
    return false if @scope.empty? || @name.empty? || @query.empty?

    MetricSample.where(tenant_id: @island.id, source: "log", name: def_key).exists?
  end

  # warehouse_data — the pre-aggregated read. nil (→ fallback) until the counter
  # tracks this def.
  def warehouse_data
    return nil unless tracked?

    env = MetricsWarehouse.query(
      @island, source: "log", metric: "log_count",
      range: @range, interval: "auto", scope: nil, name: def_key, pod: nil
    )

    points = Array(env["series"]).map do |p|
      v = p["value"].to_f

      {ts: p["ts"], value: v, formatted: v.round.to_s}
    end

    {
      value: points.sum { |p| p[:value] }.round,
      series: points,
      truncated: false,
      clamped: clamped_by_range?
    }
  rescue => e
    Rails.logger.warn("log-metric warehouse read failed def=#{def_key}: #{e.class} #{e.message}")
    nil
  end

  # ── live-scan fallback (original MVP) ────────────────────────────────────

  def live_scan_data
    Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { compute_live_scan }
  end

  def compute_live_scan
    return blank if @pods.empty? || @query.blank?

    from, until_, clamped = window

    count = LogTail::Reader.each_line(
      island_id: @island.id, pods: @pods, from: from, until_: until_,
      content_search: @query, regex: false, limit: COUNT_CAP
    ).count

    {value: count, series: [], truncated: count >= COUNT_CAP, clamped: clamped}
  end

  def blank
    {value: 0, series: [], truncated: false, clamped: false}
  end

  def window
    now = Time.current
    requested_from = now - (MetricsPageData.range_to_ms(@range) / 1000.0)
    floor = RETENTION.ago

    (requested_from < floor) ? [floor, now, true] : [requested_from, now, false]
  end

  def clamped_by_range?
    MetricsPageData.range_to_ms(@range) > (RETENTION.to_i * 1000)
  end

  def cache_key
    bucket = Time.current.to_i / CACHE_TTL
    digest = Digest::MD5.hexdigest([@pods.sort.join(","), @query].join(" "))

    ["logmetric", @island.id, @range, digest, bucket].join(":")
  end
end
