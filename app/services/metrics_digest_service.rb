# frozen_string_literal: true

# MetricsDigestService — persist + broadcast layer shared by:
#
#   - MetricsSyncIslandJob (Ruby streams /metrics/dump via
#     Voodu::Client; pipes the body into `.from_io`)
#   - PollerDigestJob (Go binary fetched + wrote the NDJSON to
#     `storage/poller/metrics/<sync_hash>/data.ndjson`; the job
#     hands the folder path to `.from_folder`)
#
# Both paths converge on `.ingest_lines`, which batches the rows
# through `MetricSample.bulk_insert` and fires the `metrics_tick`
# broadcast that wakes the chart frames.
#
# Folder shape (Go side contract):
#
#   storage/poller/metrics/<sync_hash>/
#     data.ndjson — one JSON object per line, same shape the
#                   controller's /metrics/dump endpoint emits.
#                   Lines without `ts` or `source` are skipped.
#
# Batching mirrors MetricsSyncIslandJob: BATCH_SIZE rows per
# insert_all round-trip, bounded peak memory, amortised INSERT cost.
class MetricsDigestService
  BATCH_SIZE  = 500
  NDJSON_FILE = "data.ndjson"

  def self.from_folder(folder_path:, tenant_id:)
    ndjson = Pathname.new(folder_path).join(NDJSON_FILE)
    return 0 unless File.exist?(ndjson)

    File.open(ndjson, "r") do |io|
      from_io(io: io, tenant_id: tenant_id)
    end
  end

  # from_io — entry point for the Ruby-fetch path and the file-read
  # path. Walks the stream line-by-line, parses each line into the
  # MetricSample row shape, flushes in BATCH_SIZE-row chunks.
  #
  # Returns the total row count inserted (useful for log lines +
  # the "broadcast only when total > 0" gate).
  #
  # `tenant_id` is the Island primary key (legacy domain table is
  # still `islands`, but the poller feature uses `tenant_id` as the
  # internal name end-to-end — matches the wire contract from the
  # Go binary and the column on `poller_digests`).
  def self.from_io(io:, tenant_id:)
    island = Island.find_by(id: tenant_id)
    return 0 unless island

    batch = []
    total = 0

    io.each_line do |line|
      line = line.chomp
      next if line.empty?

      row = parse_line(line)
      next unless row

      batch << row.merge(tenant_id: island.id)
      next if batch.size < BATCH_SIZE

      MetricSample.bulk_insert(batch)
      total += batch.size
      batch.clear
    end

    if batch.any?
      MetricSample.bulk_insert(batch)
      total += batch.size
    end

    broadcast_metrics_tick(island) if total.positive?
    total
  end

  # ingest_lines — convenience entry point for callers that already
  # have an Enumerable of pre-parsed Hashes (e.g. the existing
  # MetricsSyncIslandJob that walks Voodu::Client#metrics_dump via a
  # yield block).
  def self.ingest_lines(island:, rows:)
    return 0 if rows.blank?

    batch = []
    total = 0

    rows.each do |row|
      batch << row.merge(tenant_id: island.id)
      next if batch.size < BATCH_SIZE

      MetricSample.bulk_insert(batch)
      total += batch.size
      batch.clear
    end

    if batch.any?
      MetricSample.bulk_insert(batch)
      total += batch.size
    end

    broadcast_metrics_tick(island) if total.positive?
    total
  end

  # broadcast_metrics_tick — wakes every browser subscribed to the
  # island's metrics channel; each subscriber re-fetches its chart
  # frame at its current scope/range. Same shape MetricsSyncIslandJob
  # uses so the wire contract is one place.
  def self.broadcast_metrics_tick(island)
    Turbo::StreamsChannel.broadcast_action_to(
      "metrics-#{island.id}",
      action: :metrics_tick,
      target: "metrics-charts"
    )
  rescue StandardError => e
    Rails.logger.warn(
      "metrics-digest broadcast failed island=#{island.id}: #{e.class} #{e.message}"
    )
  end

  # parse_line — same tolerant shape Voodu::Client#parse_dump_line
  # uses: silently drop malformed JSON / missing-ts / missing-source
  # lines rather than poisoning the whole batch. The controller has
  # already filtered, so this is defence in depth.
  def self.parse_line(line)
    parsed = JSON.parse(line)
    ts     = parsed["ts"]
    source = parsed["source"]
    return nil if ts.blank? || source.blank?

    { source: source, ts_iso: ts, payload: line }
  rescue JSON::ParserError
    nil
  end

  private_class_method :parse_line
end
