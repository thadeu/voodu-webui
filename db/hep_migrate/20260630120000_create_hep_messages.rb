# frozen_string_literal: true

# HEP3 read model — one row per SIP message tailed from a voodu-hep3
# reader's /export NDJSON. The full line is stored verbatim in `payload`
# so the schema absorbs any future collector field without a migration
# (same JSON-first strategy as metric_samples).
#
# Real columns vs generated:
#
#   - server_id / scope / name are REAL columns: they identify the
#     reader INSTANCE the line came from and are NOT present in the
#     NDJSON (the collector doesn't know which voodu resource serves
#     it) — the poller stamps them at insert.
#   - ts_epoch (STORED) lets range scans be integer compares against
#     the indexes. The collector's `ts` is "YYYY-MM-DD HH:MM:SS.ffffff"
#     (UTC), which SQLite's strftime parses directly.
#   - call_id / x_cid / corr_id / method / response_code (VIRTUAL) are
#     the hot query fields. corr_id materialises the call-correlation
#     key COALESCE(NULLIF(x_cid,''), call_id) so grouping a call (incl.
#     B2BUA legs sharing an x_cid) is a single indexed column.
class CreateHepMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :hep_messages do |t|
      t.integer :server_id, null: false
      t.string :scope, null: false
      t.string :name, null: false
      t.text :payload, null: false

      # STORED — the integer epoch range key.
      t.virtual :ts_epoch, type: :integer,
        as: "CAST(strftime('%s', json_extract(payload, '$.ts')) AS INTEGER)",
        stored: true

      # VIRTUAL — computed at read; cheap and covered by the indexes.
      t.virtual :ts, type: :string,
        as: "json_extract(payload, '$.ts')"
      t.virtual :call_id, type: :string,
        as: "json_extract(payload, '$.call_id')"
      t.virtual :x_cid, type: :string,
        as: "json_extract(payload, '$.x_cid')"
      t.virtual :corr_id, type: :string,
        as: "COALESCE(NULLIF(json_extract(payload, '$.x_cid'), ''), json_extract(payload, '$.call_id'))"
      # `sip_method`, not `method`: an attribute named `method` would
      # shadow Object#method and break `.method(:sym)` reflection.
      t.virtual :sip_method, type: :string,
        as: "json_extract(payload, '$.method')"
      t.virtual :response_code, type: :integer,
        as: "json_extract(payload, '$.response_code')"
    end

    # Hot path #1 — a call's full timeline (ladder), ordered.
    # Covers: WHERE server_id=? AND scope=? AND name=? AND corr_id=?
    #         ORDER BY ts_epoch
    add_index :hep_messages, [:server_id, :scope, :name, :corr_id, :ts_epoch],
      name: "idx_hep_messages_call"

    # Hot path #2 — recent messages for an instance (DataTable feed).
    # Covers: WHERE server_id=? AND scope=? AND name=? ORDER BY ts_epoch DESC
    add_index :hep_messages, [:server_id, :scope, :name, :ts_epoch],
      name: "idx_hep_messages_recent"

    # Hot path #3 — the logs bridge: an app-log Call-ID → its SIP flow.
    add_index :hep_messages, [:server_id, :call_id],
      name: "idx_hep_messages_call_id"
  end
end
