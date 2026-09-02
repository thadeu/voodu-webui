# frozen_string_literal: true

# ActivityDigestService — persist layer for the poller's activity stream.
#
# The Go binary streams `/api/pat/v1/activity/dump` and writes the NDJSON to
# `storage/poller/activity/<sync_hash>/data.ndjson`; PollerDigestJob hands the
# folder here.
#
# The shape mirrors MetricsDigestService — read the file, parse tolerantly,
# flush in batches — with ONE structural difference: this writes with an
# UPSERT, not an insert.
#
# ## Why an upsert
#
# A long action is two lines (`started`, then `finished`) that describe ONE
# action, and the screen is a datatable filtered by status. Status only exists
# on the closing line. Two rows would mean every filtered page load collapses
# the pair with a window function; one merged row makes it a column with an
# index.
#
# The merge also makes re-delivery free, which matters because it is normal:
# the poller's watermark is in-memory, a restart reaches back, and the fetcher
# deliberately overlaps a second so a line sharing the newest timestamp is not
# skipped by the controller's strict `ts > since`.
#
# ## The guard
#
# The one thing an upsert must not do here is let a re-delivered `started`
# overwrite the `finished` that already closed the action — the row would go
# back to claiming it is running, and stay that way. So the DO UPDATE carries a
# WHERE on the event rank: a lower-ranked line loses.
#
# That WHERE is why this is hand-written SQL rather than `upsert_all`, which
# has no way to express a conflict-clause condition.
class ActivityDigestService
  BATCH_SIZE = 200
  NDJSON_FILE = "data.ndjson"

  # Columns in the order the statement binds them.
  COLUMNS = %w[
    server_id activity_id config_key event event_rank action ts_iso payload
  ].freeze

  def self.from_folder(folder_path:, server_id:)
    ndjson = Pathname.new(folder_path).join(NDJSON_FILE)
    return 0 unless File.exist?(ndjson)

    File.open(ndjson, "r") do |io|
      from_io(io: io, server_id: server_id)
    end
  end

  # from_io — streams NDJSON from any IO. Returns the number of lines applied
  # (rows touched, which is NOT the number of rows created: a `finished`
  # updates the row its `started` made).
  def self.from_io(io:, server_id:)
    server = Server.find_by(id: server_id)
    return 0 unless server

    batch = []
    total = 0

    io.each_line do |line|
      row = parse_line(line.chomp, server.id)
      next unless row

      batch << row
      next if batch.size < BATCH_SIZE

      total += flush(batch)
      batch.clear
    end

    total += flush(batch) if batch.any?

    broadcast_activity_tick(server) if total.positive?
    total
  end

  # flush — one statement for the whole batch.
  #
  # Rows within a single batch can conflict with EACH OTHER (a `started` and
  # its `finished` in the same tick), and SQLite refuses a multi-row upsert
  # that hits the same conflict target twice. So the batch is de-duplicated in
  # Ruby first, keeping the highest-ranked line per identity — the same rule
  # the SQL guard applies across batches, applied within one.
  def self.flush(rows)
    return 0 if rows.blank?

    deduped = collapse(rows)
    sql = upsert_sql(deduped.size)
    binds = deduped.flat_map { |row| COLUMNS.map { |col| row[col] } }

    ActivityAction.connection.exec_query(sql, "ActivityAction Upsert", binds)

    deduped.size
  end

  # collapse — last-writer-wins per identity, ranked. Preserves arrival order
  # for everything else so a batch stays readable in a log.
  def self.collapse(rows)
    by_identity = {}

    rows.each do |row|
      key = [row["activity_id"], row["config_key"]]
      current = by_identity[key]

      by_identity[key] = row if current.nil? || row["event_rank"] >= current["event_rank"]
    end

    by_identity.values
  end

  # upsert_sql — INSERT … ON CONFLICT DO UPDATE, guarded.
  #
  # The SET list rewrites every column from the incoming row: the closing line
  # carries a superset of what the opening one did (the controller enriches its
  # record as the action progresses and writes the whole thing at the end), so
  # taking it wholesale is correct and leaves no stale halves behind.
  #
  # The WHERE is the guard. `>=` rather than `>` so an identical re-delivery
  # still refreshes the payload — harmless, and it means a corrected line can
  # land without inventing a version counter.
  def self.upsert_sql(count)
    placeholders = Array.new(count) { "(#{Array.new(COLUMNS.size, "?").join(", ")})" }.join(", ")

    <<~SQL
      INSERT INTO activity_actions (#{COLUMNS.join(", ")})
      VALUES #{placeholders}
      ON CONFLICT (server_id, activity_id, config_key) DO UPDATE SET
        event      = excluded.event,
        event_rank = excluded.event_rank,
        action     = excluded.action,
        ts_iso     = excluded.ts_iso,
        payload    = excluded.payload
      WHERE excluded.event_rank >= activity_actions.event_rank
    SQL
  end

  # parse_line — tolerant, like the metrics ingest: a malformed or incomplete
  # line is dropped rather than poisoning the batch. The controller has already
  # filtered, so this is defence in depth.
  #
  # `id`, `ts`, `event` and `action` are the four fields a row cannot be built
  # without. A line missing any of them is not a partial action we could show —
  # it is a line we cannot place on a timeline or merge with its pair.
  def self.parse_line(line, server_id)
    return nil if line.empty?

    parsed = JSON.parse(line)

    activity_id = parsed["id"]
    ts = parsed["ts"]
    event = parsed["event"]
    action = parsed["action"]
    return nil if activity_id.blank? || ts.blank? || event.blank? || action.blank?

    rank = ActivityAction::EVENT_RANK[event]
    return nil if rank.nil?

    {
      "server_id" => server_id,
      "activity_id" => activity_id,
      # Part of the identity: one `vd config set` writes a line per key, all
      # sharing an id. Empty for every other action — never nil, because
      # SQLite treats NULLs as distinct in a unique index and every
      # re-delivered apply would insert a second row.
      "config_key" => parsed["config_key"].to_s,
      "event" => event,
      "event_rank" => rank,
      "action" => action,
      "ts_iso" => ts,
      "payload" => line
    }
  rescue JSON::ParserError
    nil
  end

  # broadcast_activity_tick — wakes browsers on the activity screen so an
  # action that is still running resolves without a manual refresh. Same wire
  # shape as the metrics tick.
  def self.broadcast_activity_tick(server)
    Turbo::StreamsChannel.broadcast_action_to(
      "activity-#{server.id}",
      action: :activity_tick,
      target: "activity-table"
    )
  rescue => e
    Rails.logger.warn(
      "activity-digest broadcast failed server=#{server.id}: #{e.class} #{e.message}"
    )
  end

  private_class_method :parse_line, :flush, :collapse, :upsert_sql
end
