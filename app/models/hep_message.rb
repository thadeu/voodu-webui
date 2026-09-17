# frozen_string_literal: true

# HepMessage — one captured SIP message in the local read model, tailed
# from a voodu-hep3 reader's /export NDJSON by Hep3PollerJob.
#
# JSON-first (see db/hep_migrate/*_create_hep_messages.rb): the raw line
# lives in `payload`; ts/call_id/x_cid/corr_id/method/response_code are
# generated columns. `server_id` references servers.id; `scope`/`name`
# identify the reader instance the line came from (the poller stamps
# these — they're not in the NDJSON). No `belongs_to :server`: the
# Server model lives in the primary DB and cross-DB joins are out of
# scope.
class HepMessage < HepRecord
  # A Server, never an id — see ServerScoped.
  extend ServerScoped

  # bulk_insert (BulkInsertable): Hep3PollerJob hands column-shaped rows
  # [{ server_id:, scope:, name:, payload: }]; generated columns are computed
  # by SQLite. parsed_payload (PayloadParsable) exposes `payload` as a Hash.
  include BulkInsertable
  include PayloadParsable

  # Filterable fields → the SQL the substring filter runs against. Hot
  # fields use their generated column; the rest fall back to json_extract
  # on the raw payload. The DataTable filter only accepts a field present
  # here, so the field name is NEVER attacker-controlled SQL (the value
  # is always a bind param).
  FILTER_COLUMNS = {
    "ts" => "ts",
    "call_id" => "call_id",
    "x_cid" => "x_cid",
    "corr_id" => "corr_id",
    "call_key" => "call_key",
    "method" => "sip_method",
    "response_code" => "response_code"
  }.freeze

  JSON_FILTER_FIELDS = %w[
    from_user to_user ruri src_ip dst_ip src_port dst_port node_id user_agent cseq raw_sip
  ].freeze

  # filter_expr — the SQL expression to LIKE-match `field` against, or nil
  # when the field isn't filterable (→ the filter is ignored, never
  # injected). Both branches return a literal from a frozen allowlist.
  def self.filter_expr(field)
    return FILTER_COLUMNS[field] if FILTER_COLUMNS.key?(field)

    "json_extract(payload, '$.#{field}')" if JSON_FILTER_FIELDS.include?(field)
  end

  # bulk_insert — the poller's write path, with the call resolved on the way
  # in: every row gets its `call_key` from HepCallKeys against the rows this
  # reader instance already holds (see that class for why ingest, not query).
  # Rows are grouped per instance because the key space is per instance.
  def self.bulk_insert(rows)
    return 0 if rows.blank?

    rows.group_by { |r| [r[:server_id], r[:scope], r[:name]] }.each do |(server_id, scope, name), group|
      HepCallKeys.new(where(server_id: server_id, scope: scope, name: name)).assign(group)
    end

    insert_all(rows)
    rows.size
  end

  # for_instance — narrow to one reader (scope, name) of a server.
  #
  # Takes a Server, never an id: these rows carry a bare server_id with no org
  # column, so the object is the only proof the caller was allowed to ask (see
  # ServerScoped). Every read below funnels through here, which is why this is
  # the one place that has to coerce.
  scope :for_instance, ->(server:, scope:, name:) {
    where(server_id: HepMessage.server_id_of(server), scope: scope, name: name)
  }

  # page — newest-first slice for the DataTable. `filter` is an optional
  # {field:, value:} substring match (ignored unless the field is in the
  # allowlist). `before_id` pages older (infinite scroll); `since_id`
  # pulls only rows newer than a watermark (live-append). id ordering is
  # the stable arrival order — ts ties at the second don't reshuffle.
  def self.page(server:, scope:, name:, where_sql: nil, where_binds: [], limit: 100, before_id: nil, since_id: nil, min_code: nil, ts_from: nil, ts_to: nil)
    ensure_regexp! if where_sql.present?

    rel = for_instance(server: server, scope: scope, name: name)
    rel = rel.where("hep_messages.id < ?", before_id) if before_id
    rel = rel.where("hep_messages.id > ?", since_id) if since_id
    rel = rel.where("ts_epoch >= ?", ts_from) if ts_from
    rel = rel.where("ts_epoch <= ?", ts_to) if ts_to
    rel = rel.where("response_code >= ?", min_code) if min_code
    rel = rel.where(where_sql, *where_binds) if where_sql.present?

    rel.order(id: :desc).limit(limit)
  end

  # calls_page — one row per call (grouped by call_key), most-recently-
  # active first. Backs the "Calls" view: each row summarizes a call
  # (parties, message count, time span, a result-code hint). `before_epoch`
  # pages older calls (the cursor is the group's MAX(ts_epoch), which the
  # source also exposes as the row "id"). Returns an Array of column
  # arrays (see CALLS_SELECT order) — the source maps them to hashes.
  CALLS_SELECT = [
    "call_key",
    "MAX(ts_epoch)",
    "MIN(ts)",
    "MAX(ts)",
    "COUNT(*)",
    "MAX(response_code)",
    "MAX(json_extract(payload, '$.from_user'))",
    "MAX(json_extract(payload, '$.to_user'))",
    "GROUP_CONCAT(DISTINCT sip_method)"
  ].freeze

  def self.calls_page(server:, scope:, name:, where_sql: nil, where_binds: [], limit: 100, before_epoch: nil, ts_from: nil, ts_to: nil)
    ensure_regexp! if where_sql.present?

    rel = for_instance(server: server, scope: scope, name: name)
    rel = rel.where("ts_epoch >= ?", ts_from) if ts_from
    rel = rel.where("ts_epoch <= ?", ts_to) if ts_to
    rel = rel.where(where_sql, *where_binds) if where_sql.present?
    rel = rel.group(:call_key).order(Arel.sql("MAX(ts_epoch) DESC")).limit(limit)
    rel = rel.having("MAX(ts_epoch) < ?", before_epoch) if before_epoch

    rel.pluck(*CALLS_SELECT.map { |expr| Arel.sql(expr) })
  end

  # count_series — per-bucket COUNT for a chart panel: how many rows (matching
  # the same view + filter as the table) fall in each `bucket`-second window of
  # [ts_from, ts_to). Returns [[bucket_epoch, count], …] ascending, ready to
  # feed a sparkline. `distinct_corr` counts calls (one per call_key) instead of
  # messages; `min_code` narrows to errors (4xx/5xx).
  def self.count_series(server:, scope:, name:, ts_from:, ts_to:, bucket:, where_sql: nil, where_binds: [], distinct_corr: false, min_code: nil)
    ensure_regexp! if where_sql.present?

    b = [bucket.to_i, 1].max
    rel = for_instance(server: server, scope: scope, name: name)
      .where("ts_epoch >= ? AND ts_epoch < ?", ts_from.to_i, ts_to.to_i)
    rel = rel.where("response_code >= ?", min_code) if min_code
    rel = rel.where(where_sql, *where_binds) if where_sql.present?

    bucket_sql = "(ts_epoch / #{b}) * #{b}"
    count_sql = distinct_corr ? "COUNT(DISTINCT call_key)" : "COUNT(*)"

    rel.group(Arel.sql(bucket_sql)).order(Arel.sql(bucket_sql))
      .pluck(Arel.sql(bucket_sql), Arel.sql(count_sql))
  end

  # group_snapshot — ONE aggregated value per distinct value of `group_expr` over
  # [ts_from, ts_to), for a group-by chart's SNAPSHOT (Table / Bar / Number).
  # `agg_sql` is COUNT(*) or COUNT(DISTINCT <expr>); `group_expr`, `agg_sql` and
  # `sort_expr` are built by the caller from HepMessage.filter_expr (the frozen
  # allowlist), so no field is ever attacker SQL. NULL groups (a missing field)
  # are dropped. Sorted by `sort_expr` (default: the agg value) and capped at
  # `limit`. Returns [[group_value, value], …].
  def self.group_snapshot(server:, scope:, name:, ts_from:, ts_to:, group_expr:, agg_sql:,
    sort_expr: nil, sort_dir: :desc, limit: nil, min_code: nil, where_sql: nil, where_binds: [])
    ensure_regexp! if where_sql.present?

    rel = for_instance(server: server, scope: scope, name: name)
      .where("ts_epoch >= ? AND ts_epoch < ?", ts_from.to_i, ts_to.to_i)
      .where("#{group_expr} IS NOT NULL")
    rel = rel.where("response_code >= ?", min_code) if min_code
    rel = rel.where(where_sql, *where_binds) if where_sql.present?

    dir = (sort_dir.to_s == "asc") ? "ASC" : "DESC"
    rel = rel.group(Arel.sql(group_expr)).order(Arel.sql("#{sort_expr || agg_sql} #{dir}"))
    rel = rel.limit(limit) if limit

    rel.pluck(Arel.sql(group_expr), Arel.sql(agg_sql))
  end

  # group_series — per-(group, bucket) aggregate for a GIVEN set of group values
  # (the top-N from group_snapshot), so a Line/Area draws one series per group
  # over time. Same allowlist-built `group_expr`/`agg_sql`; `groups` are bind
  # values. Returns [[group_value, bucket_epoch, value], …] ascending by bucket.
  def self.group_series(server:, scope:, name:, ts_from:, ts_to:, bucket:, group_expr:, agg_sql:,
    groups:, min_code: nil, where_sql: nil, where_binds: [])
    return [] if groups.blank?

    ensure_regexp! if where_sql.present?

    b = [bucket.to_i, 1].max
    bucket_sql = "(ts_epoch / #{b}) * #{b}"

    rel = for_instance(server: server, scope: scope, name: name)
      .where("ts_epoch >= ? AND ts_epoch < ?", ts_from.to_i, ts_to.to_i)
      .where("#{group_expr} IN (?)", groups)
    rel = rel.where("response_code >= ?", min_code) if min_code
    rel = rel.where(where_sql, *where_binds) if where_sql.present?

    rel.group(Arel.sql(group_expr), Arel.sql(bucket_sql)).order(Arel.sql(bucket_sql))
      .pluck(Arel.sql(group_expr), Arel.sql(bucket_sql), Arel.sql(agg_sql))
  end

  # locate_by_call_id — the most recent captured message whose SIP Call-ID is
  # `call_id`, across ALL reader instances of the server. Backs the Logs →
  # call-flow bridge: a FreeSWITCH log line carries a `Call-ID:`, and this
  # resolves which reader has it + the corr_id (which folds x_cid → call_id).
  # nil when the call wasn't captured.
  def self.locate_by_call_id(server, call_id)
    where(server_id: server_id_of(server), call_id: call_id.to_s).order(id: :desc).first
  end

  # for_call — every message of one call (by the correlation key), in
  # chronological order. Backs the call-flow ladder. corr_id already
  # folds x_cid → call_id, so this joins B2BUA legs that share an x_cid.
  #
  # Orders by `ts` (the full MICROSECOND timestamp), NOT `ts_epoch` (which
  # is truncated to seconds): a whole SIP dialog lands in the same second,
  # so ts_epoch ties and the fallback to arrival `id` reorders the ladder
  # (a 100 Trying that the poller inserted before its INVITE would render
  # first). `ts` is fixed-width ISO text, so lexicographic == chronological.
  scope :for_call, ->(server:, scope:, name:, corr_id:) {
    instance = for_instance(server: server, scope: scope, name: name)
    instance.where(call_id: HepMessage.call_ids_for(instance, corr_id)).order(:ts, :id)
  }

  # call_ids_for — every SIP Call-ID of the call that `key` names, whatever
  # the caller holds: a call_key (Calls view row), a Call-ID (a FreeSWITCH
  # log line) or an X-CID (a DataTable cell).
  #
  # The ladder must show EVERY message that shares a Call-ID with the call —
  # that is what an operator means by "the call" — so this does not trust
  # call_key alone. Start from the rows the key reaches (by call_key, by
  # call_id or by x_cid), then walk the correlation graph both ways: a Call-ID
  # reaches the x_cids seen on it, an x_cid reaches every Call-ID seen with
  # it. Two rounds cover a B2BUA plus one hop of header inconsistency per leg;
  # the loop stops early once the set is stable. Bounded: at most 5 small
  # indexed queries per ladder open. call_key stays the key for COUNTING calls
  # (the Calls view); this is the key for SHOWING one.
  def self.call_ids_for(instance, key)
    key = key.to_s
    return [] if key.empty?

    # A sentinel X-CID ("unknown") is never a key and never a hop — see
    # HepCallKeys::SENTINELS. Opening by one would be "every outbound call".
    return [] if HepCallKeys.sentinel?(key)

    call_ids = instance.where(call_key: key).or(instance.where(call_id: key)).or(instance.where(x_cid: key))
      .distinct.pluck(:call_id).reject(&:blank?)
    return [] if call_ids.empty?

    2.times do
      x_cids = instance.where(call_id: call_ids).where.not(x_cid: [nil, ""]).distinct.pluck(:x_cid)
        .reject { |x| HepCallKeys.sentinel?(x) }
      break if x_cids.empty?

      grown = (call_ids + instance.where(x_cid: x_cids).distinct.pluck(:call_id)).uniq
      break if grown.size == call_ids.size

      call_ids = grown
    end

    call_ids
  end

  # backfill_call_keys! — the one-off transitive pass for rows written before
  # call_key existed (the migration seeds them with corr_id, which splits a
  # call the way HepCallKeys explains). Walks each reader instance in arrival
  # order with EMPTY maps, so stored keys never leak back in.
  #
  # Two passes per instance, and the second is not optional: a union found
  # late in the walk (the INVITE that links leg A to leg B arrives after
  # both legs were already keyed) only moves the maps, so the rows keyed
  # BEFORE the union still carry the loser. Pass 1 learns every union; pass
  # 2 re-resolves each row against the settled maps and rewrites what
  # differs. Returns the number of rows rewritten.
  def self.backfill_call_keys!(batch: 2_000)
    rewritten = 0

    distinct.pluck(:server_id, :scope, :name).each do |server_id, scope, name|
      instance = where(server_id: server_id, scope: scope, name: name)
      resolver = HepCallKeys.new(instance, seed: false)
      rows = instance.order(:id).select(:id, :call_id, :x_cid, :call_key)

      rows.find_each(batch_size: batch) { |row| resolver.key_for(row.call_id, row.x_cid) }

      pending = Hash.new { |h, k| h[k] = [] }

      rows.find_each(batch_size: batch) do |row|
        key = resolver.key_for(row.call_id, row.x_cid)
        pending[key] << row.id if key != row.call_key.to_s && !key.empty?
      end

      pending.each do |key, ids|
        ids.each_slice(batch) { |slice| rewritten += instance.where(id: slice).update_all(call_key: key) }
      end
    end

    rewritten
  end

  # payload_json — parsed view of the raw NDJSON line, for single-row
  # reads (the full SIP record incl. raw_sip). Bulk reads should select
  # the generated columns / json_extract in SQL.
  alias_method :payload_json, :parsed_payload
end
