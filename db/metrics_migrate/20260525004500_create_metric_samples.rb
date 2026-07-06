# frozen_string_literal: true

# Metrics warehouse — one row per NDJSON line published by the
# controller's sampler (15s tick). The full line is stored verbatim
# in `payload` so the schema absorbs ANY future controller field
# addition without a migration.
#
# Generated columns extract the hot identity fields for indexing:
#
#   - ts_epoch (STORED) — paid once at write, lets range scans be
#     pure integer compares against the partial indexes (no JSON
#     extract on the hot path).
#   - scope / name / pod (VIRTUAL) — computed at read; cheap because
#     they're indexed. NDJSON field is `container` ("voodu-x-web.a3f9")
#     but throughout the WebUI we use the operator-facing vocab "pod",
#     so the virtual column extracts $.container and exposes it as
#     `pod`.
#
# Partial indexes (`WHERE source = X`) keep the B-trees lean —
# system rows don't pollute the pod index and vice-versa.
#
# Vocab note: foreign key is `server_id` (forward-compatible with a
# future Server → Server rename) referencing servers.id. We
# intentionally don't add a Rails-level `belongs_to :server` because
# the warehouse lives in a separate database and cross-DB joins are
# out of scope; the model exposes scopes that take server_id directly.
class CreateMetricSamples < ActiveRecord::Migration[8.1]
  def change
    create_table :metric_samples do |t|
      t.integer :server_id, null: false
      t.string :source, null: false
      t.string :ts_iso, null: false
      t.text :payload, null: false

      # STORED — the only generated column we materialise on disk.
      # Range scans against partial indexes need this to be a column,
      # not an expression, for the planner to pick the index.
      t.virtual :ts_epoch, type: :integer,
        as: "CAST(strftime('%s', ts_iso) AS INTEGER)",
        stored: true

      # VIRTUAL — computed at read time. Free for un-indexed reads,
      # and the partial indexes below cover the indexed paths.
      t.virtual :scope, type: :string,
        as: "json_extract(payload, '$.scope')"
      t.virtual :name, type: :string,
        as: "json_extract(payload, '$.name')"
      t.virtual :pod, type: :string,
        as: "json_extract(payload, '$.container')"

      # No t.timestamps — payload's ts_iso is the source of truth.
      # created_at would just duplicate "when did we ingest" which
      # isn't queried (sync jobs only care about ts_epoch).
    end

    # Hot path #1: system metric over time range.
    # Covers: WHERE server_id = ? AND source = 'system' AND ts_epoch BETWEEN ? AND ?
    add_index :metric_samples, [:server_id, :source, :ts_epoch],
      where: "source = 'system'",
      name: "idx_metric_samples_system"

    # Hot path #2: specific pod metric over time range.
    # Covers: WHERE server_id = ? AND source = 'pod'
    #           AND scope = ? AND name = ? [AND pod = ?]
    #           AND ts_epoch BETWEEN ? AND ?
    # `pod` is the rightmost column so prefix-matches without pod
    # (e.g. all replicas of a resource) still use the index.
    add_index :metric_samples, [:server_id, :source, :scope, :name, :pod, :ts_epoch],
      where: "source = 'pod'",
      name: "idx_metric_samples_pod"

    # Sync watermark — used by MetricsSyncServerJob to derive `since`
    # for the next incremental pull. MAX(ts_epoch) per server is the
    # single hottest query in the warehouse; this dedicated index
    # makes it O(log n) instead of scanning the partial indexes.
    add_index :metric_samples, [:server_id, :ts_epoch],
      name: "idx_metric_samples_watermark"
  end
end
