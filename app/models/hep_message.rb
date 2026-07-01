# frozen_string_literal: true

# HepMessage — one captured SIP message in the local read model, tailed
# from a voodu-hep3 reader's /export NDJSON by Hep3PollerJob.
#
# JSON-first (see db/hep_migrate/*_create_hep_messages.rb): the raw line
# lives in `payload`; ts/call_id/x_cid/corr_id/method/response_code are
# generated columns. `tenant_id` references islands.id; `scope`/`name`
# identify the reader instance the line came from (the poller stamps
# these — they're not in the NDJSON). No `belongs_to :island`: the
# Island model lives in the primary DB and cross-DB joins are out of
# scope.
class HepMessage < HepRecord
  # bulk_insert — primary write path (Hep3PollerJob). `rows` are Hashes
  # shaped like the real columns: [{ tenant_id:, scope:, name:, payload: }].
  # Generated columns are computed by SQLite. insert_all → one round-trip
  # per batch instead of per row.
  def self.bulk_insert(rows)
    return 0 if rows.blank?

    insert_all(rows)
    rows.size
  end

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

  # for_instance — narrow to one reader (scope, name) of a tenant.
  scope :for_instance, ->(tenant_id:, scope:, name:) {
    where(tenant_id: tenant_id, scope: scope, name: name)
  }

  # page — newest-first slice for the DataTable. `filter` is an optional
  # {field:, value:} substring match (ignored unless the field is in the
  # allowlist). `before_id` pages older (infinite scroll); `since_id`
  # pulls only rows newer than a watermark (live-append). id ordering is
  # the stable arrival order — ts ties at the second don't reshuffle.
  def self.page(tenant_id:, scope:, name:, where_sql: nil, where_binds: [], limit: 100, before_id: nil, since_id: nil, min_code: nil, ts_from: nil, ts_to: nil)
    ensure_regexp! if where_sql.present?

    rel = for_instance(tenant_id: tenant_id, scope: scope, name: name)
    rel = rel.where("hep_messages.id < ?", before_id) if before_id
    rel = rel.where("hep_messages.id > ?", since_id) if since_id
    rel = rel.where("ts_epoch >= ?", ts_from) if ts_from
    rel = rel.where("ts_epoch <= ?", ts_to) if ts_to
    rel = rel.where("response_code >= ?", min_code) if min_code
    rel = rel.where(where_sql, *where_binds) if where_sql.present?

    rel.order(id: :desc).limit(limit)
  end

  # calls_page — one row per call (grouped by corr_id), most-recently-
  # active first. Backs the "Calls" view: each row summarises a call
  # (parties, message count, time span, a result-code hint). `before_epoch`
  # pages older calls (the cursor is the group's MAX(ts_epoch), which the
  # source also exposes as the row "id"). Returns an Array of column
  # arrays (see CALLS_SELECT order) — the source maps them to hashes.
  CALLS_SELECT = [
    "corr_id",
    "MAX(ts_epoch)",
    "MIN(ts)",
    "MAX(ts)",
    "COUNT(*)",
    "MAX(response_code)",
    "MAX(json_extract(payload, '$.from_user'))",
    "MAX(json_extract(payload, '$.to_user'))",
    "GROUP_CONCAT(DISTINCT sip_method)"
  ].freeze

  def self.calls_page(tenant_id:, scope:, name:, where_sql: nil, where_binds: [], limit: 100, before_epoch: nil, ts_from: nil, ts_to: nil)
    ensure_regexp! if where_sql.present?

    rel = for_instance(tenant_id: tenant_id, scope: scope, name: name)
    rel = rel.where("ts_epoch >= ?", ts_from) if ts_from
    rel = rel.where("ts_epoch <= ?", ts_to) if ts_to
    rel = rel.where(where_sql, *where_binds) if where_sql.present?
    rel = rel.group(:corr_id).order(Arel.sql("MAX(ts_epoch) DESC")).limit(limit)
    rel = rel.having("MAX(ts_epoch) < ?", before_epoch) if before_epoch

    rel.pluck(*CALLS_SELECT.map { |expr| Arel.sql(expr) })
  end

  # count_series — per-bucket COUNT for a chart panel: how many rows (matching
  # the same view + filter as the table) fall in each `bucket`-second window of
  # [ts_from, ts_to). Returns [[bucket_epoch, count], …] ascending, ready to
  # feed a sparkline. `distinct_corr` counts calls (one per corr_id) instead of
  # messages; `min_code` narrows to errors (4xx/5xx).
  def self.count_series(tenant_id:, scope:, name:, ts_from:, ts_to:, bucket:, where_sql: nil, where_binds: [], distinct_corr: false, min_code: nil)
    ensure_regexp! if where_sql.present?

    b = [bucket.to_i, 1].max
    rel = for_instance(tenant_id: tenant_id, scope: scope, name: name)
      .where("ts_epoch >= ? AND ts_epoch < ?", ts_from.to_i, ts_to.to_i)
    rel = rel.where("response_code >= ?", min_code) if min_code
    rel = rel.where(where_sql, *where_binds) if where_sql.present?

    bucket_sql = "(ts_epoch / #{b}) * #{b}"
    count_sql = distinct_corr ? "COUNT(DISTINCT corr_id)" : "COUNT(*)"

    rel.group(Arel.sql(bucket_sql)).order(Arel.sql(bucket_sql))
      .pluck(Arel.sql(bucket_sql), Arel.sql(count_sql))
  end

  # for_call — every message of one call (by the correlation key), in
  # chronological order. Backs the call-flow ladder. corr_id already
  # folds x_cid → call_id, so this joins B2BUA legs that share an x_cid.
  scope :for_call, ->(tenant_id:, scope:, name:, corr_id:) {
    for_instance(tenant_id: tenant_id, scope: scope, name: name)
      .where(corr_id: corr_id).order(:ts_epoch, :id)
  }

  # payload_json — parsed view of the raw NDJSON line, for single-row
  # reads (the full SIP record incl. raw_sip). Bulk reads should select
  # the generated columns / json_extract in SQL.
  def payload_json
    @payload_json ||= JSON.parse(payload)
  rescue JSON::ParserError
    {}
  end
end
