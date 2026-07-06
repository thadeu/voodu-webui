# frozen_string_literal: true

# Hep3PollerJob — drains ONE voodu-hep3 reader instance's /export NDJSON
# tail into the local read model (HepMessage on the `hep` SQLite DB).
#
# Cursor mechanics (the HEP3 analogue of MetricsSyncServerJob's ts
# watermark):
#
#   - The reader reports its resume point as an opaque "<file>:<offset>"
#     cursor in X-Hep-Cursor and caps each response at ~8 MiB. We persist
#     the cursor (HepCursor) and pass it as `?since=` so each poll pulls
#     strictly newer lines.
#   - One tick LOOPS: a cold instance (empty cursor) backfills the
#     reader's retention 8 MiB at a time until the body comes back empty;
#     a caught-up instance returns 0 bytes on the first call and the job
#     is a fast no-op.
#
# No duplicates: a page's inserts and its cursor advance commit in ONE
# transaction (both models live in the `hep` DB → same connection), and
# data is only committed when paired with a forward cursor. If the
# transaction fails, the cursor doesn't move and the next tick re-pulls
# the same page cleanly.
class Hep3PollerJob < ApplicationJob
  queue_as :default

  # Cap rows per INSERT — SQLite binds one parameter per value, so a
  # single huge insert_all would blow SQLITE_MAX_VARIABLE_NUMBER. 500 ×
  # 4 cols is comfortably under the limit and amortises INSERT cost.
  BATCH_SIZE = 500

  # Safety bound on a single tick's backfill drain (50 × ~8 MiB). The
  # rest streams in on later ticks — the cursor is persisted per page.
  MAX_PAGES = 50

  # Won't self-recover within the retry budget — a revoked/under-scoped
  # PAT (auth) or a mistyped reader instance (404 from the PAT proxy).
  # The orchestrator re-enqueues every tick anyway, so discard instead
  # of burning Solid Queue retries.
  discard_on Voodu::Client::AuthError
  discard_on Voodu::Client::NotFoundError

  def perform(server_id, scope, name)
    server = Server.find_by(id: server_id)
    return unless server # deleted between orchestrator + job dispatch

    drain(server, scope, name, Voodu::Client.new(server))
  end

  # drain — the testable core: pulls /export pages through `client` and
  # commits each page (inserts + cursor advance) in ONE transaction so a
  # crash never leaves the watermark ahead of the data (→ a gap) or
  # behind it (→ duplicates). Returns the number of rows inserted.
  #
  # `client` is injected so tests drive it with a fake reader instead of
  # stubbing the network (same seam as LogTailServerJob#poll_once).
  def drain(server, scope, name, client)
    cursor = HepCursor.cursor_for(server.id, scope, name)
    inserted = 0
    pages = 0

    while pages < MAX_PAGES
      body, next_cursor = client.hep_export(scope, name, since: cursor)
      next_cursor = next_cursor.to_s

      rows = parse_lines(body, server.id, scope, name)
      break if rows.empty? # caught up — no new complete lines

      # We have data: require a forward cursor to commit it, else next
      # tick would re-read these same lines. The reader always sends one;
      # bail defensively rather than risk duplicates if it didn't.
      break if next_cursor.empty? || next_cursor == cursor

      HepRecord.transaction do
        rows.each_slice(BATCH_SIZE) { |slice| HepMessage.bulk_insert(slice) }
        HepCursor.advance(server.id, scope, name, next_cursor)
      end

      inserted += rows.size
      cursor = next_cursor
      pages += 1
    end

    Rails.logger.info(
      "hep3-poll server=#{server.key} server=#{server.id} reader=#{scope}/#{name} " \
      "inserted=#{inserted} pages=#{pages} cursor=#{cursor}"
    )

    inserted
  end

  private

  # parse_lines — NDJSON body → bulk_insert-ready row Hashes. scope/name
  # identify the reader instance (not present in the line); server_id is
  # the server. Tolerant: a malformed or ts-less line is skipped so one
  # bad line never poisons the page.
  def parse_lines(body, server_id, scope, name)
    body.to_s.each_line.filter_map do |raw|
      line = raw.chomp
      next if line.empty?

      parsed = JSON.parse(line)
      next if parsed["ts"].blank?

      {server_id: server_id, scope: scope, name: name, payload: line}
    rescue JSON::ParserError
      nil
    end
  end
end
