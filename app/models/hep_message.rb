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

  # for_instance — narrow to one reader (scope, name) of a tenant.
  scope :for_instance, ->(tenant_id:, scope:, name:) {
    where(tenant_id: tenant_id, scope: scope, name: name)
  }

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
