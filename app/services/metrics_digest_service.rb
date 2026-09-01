# frozen_string_literal: true

# MetricsDigestService — persist + broadcast layer for the poller's metrics
# stream. The Go binary streams /metrics/dump and writes the NDJSON to
# `storage/poller/metrics/<sync_hash>/data.ndjson`; PollerDigestJob hands
# the folder to `.from_folder`, which batches the rows through
# `MetricSample.bulk_insert` and fires the `metrics_tick` broadcast that
# wakes the chart frames.
#
# There used to be a second writer — a Ruby job streaming the same endpoint
# — and this class was where both converged. The job is gone; the batching
# it needed is still the right shape for the digest.
#
# Folder shape (Go side contract):
#
#   storage/poller/metrics/<sync_hash>/
#     data.ndjson — one JSON object per line, same shape the
#                   controller's /metrics/dump endpoint emits.
#                   Lines without `ts` or `source` are skipped.
#
# BATCH_SIZE rows per insert_all round-trip: bounded peak memory,
# amortised INSERT cost.
class MetricsDigestService
  BATCH_SIZE = 500
  NDJSON_FILE = "data.ndjson"

  def self.from_folder(folder_path:, server_id:)
    ndjson = Pathname.new(folder_path).join(NDJSON_FILE)
    return 0 unless File.exist?(ndjson)

    File.open(ndjson, "r") do |io|
      from_io(io: io, server_id: server_id)
    end
  end

  # from_io — streams NDJSON from any IO; the file-read
  # path. Walks the stream line-by-line, parses each line into the
  # MetricSample row shape, flushes in BATCH_SIZE-row chunks.
  #
  # Returns the total row count inserted (useful for log lines +
  # the "broadcast only when total > 0" gate).
  #
  # `server_id` is the Server primary key (legacy domain table is
  # still `servers`, but the poller feature uses `server_id` as the
  # internal name end-to-end — matches the wire contract from the
  # Go binary and the column on `poller_digests`).
  def self.from_io(io:, server_id:)
    server = Server.find_by(id: server_id)
    return 0 unless server

    batch = []
    total = 0

    io.each_line do |line|
      line = line.chomp
      next if line.empty?

      row = parse_line(line)
      next unless row

      batch << row.merge(server_id: server.id)
      next if batch.size < BATCH_SIZE

      MetricSample.bulk_insert(batch)
      total += batch.size
      batch.clear
    end

    if batch.any?
      MetricSample.bulk_insert(batch)
      total += batch.size
    end

    broadcast_metrics_tick(server) if total.positive?
    total
  end

  # ingest_lines — entry point for callers that already hold an Enumerable
  # of pre-parsed Hashes. `from_folder` and `from_io` both end up here.
  def self.ingest_lines(server:, rows:)
    return 0 if rows.blank?

    batch = []
    total = 0

    rows.each do |row|
      batch << row.merge(server_id: server.id)
      next if batch.size < BATCH_SIZE

      MetricSample.bulk_insert(batch)
      total += batch.size
      batch.clear
    end

    if batch.any?
      MetricSample.bulk_insert(batch)
      total += batch.size
    end

    broadcast_metrics_tick(server) if total.positive?
    total
  end

  # broadcast_metrics_tick — wakes every browser subscribed to the
  # server's metrics channel; each subscriber re-fetches its chart
  # frame at its current scope/range. One method so the wire contract
  # lives in one place.
  def self.broadcast_metrics_tick(server)
    Turbo::StreamsChannel.broadcast_action_to(
      "metrics-#{server.id}",
      action: :metrics_tick,
      target: "metrics-charts"
    )
  rescue => e
    Rails.logger.warn(
      "metrics-digest broadcast failed server=#{server.id}: #{e.class} #{e.message}"
    )
  end

  # parse_line — same tolerant shape Voodu::Client#parse_dump_line
  # uses: silently drop malformed JSON / missing-ts / missing-source
  # lines rather than poisoning the whole batch. The controller has
  # already filtered, so this is defence in depth.
  def self.parse_line(line)
    parsed = JSON.parse(line)
    ts = parsed["ts"]
    source = parsed["source"]
    return nil if ts.blank? || source.blank?

    {source: source, ts_iso: ts, payload: line}
  rescue JSON::ParserError
    nil
  end

  private_class_method :parse_line
end
