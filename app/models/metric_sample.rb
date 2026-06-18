# frozen_string_literal: true

# MetricSample — local warehouse row for time-series metrics pulled
# from a voodu controller's NDJSON stream.
#
# Lives in a dedicated SQLite database (`metrics`) so the high-volume
# sync writes (every 30s × all tenants) don't contend with the primary
# DB. The schema is JSON-first: each row stores the raw NDJSON line
# verbatim in `payload`, with virtual generated columns indexing the
# hot identity fields (scope, name, pod). See
# db/metrics_migrate/*_create_metric_samples.rb for the schema rationale.
#
# Vocab:
#   - `tenant_id` refs islands.id (forward-compatible with a future
#     Island → Tenant rename).
#   - `pod` is the operator-facing name for what the NDJSON calls
#     `container` (e.g. "voodu-x-web.a3f9"). The virtual column
#     extracts $.container; queries speak `pod`.
#
# Cross-DB note: no `belongs_to :island` — the Island model lives in
# the primary DB and cross-DB ActiveRecord joins are out of scope.
# Callers pass `tenant_id` directly to the scopes below.
class MetricSample < MetricsRecord
  # bulk_insert — primary write path, called by MetricsSyncIslandJob.
  # `rows` is an Array of Hashes shaped exactly like the columns:
  #   [{ tenant_id:, source:, ts_iso:, payload: }, ...]
  # Generated columns (ts_epoch / scope / name / pod) are computed by
  # SQLite automatically — STORED at write, VIRTUAL on read. We use
  # `insert_all` (not `create!`) so a 1000-row batch is one round-trip
  # instead of one per row.
  def self.bulk_insert(rows)
    return 0 if rows.blank?

    insert_all(rows)
    rows.size
  end

  # last_ts_for — highest ts_epoch we've persisted for this tenant.
  # MetricsSyncIslandJob uses this as the `?since=<ts>` boundary on
  # the next incremental pull. Hits idx_metric_samples_watermark.
  #
  # Returns 0 when the warehouse is empty for this tenant (cold boot
  # / first sync). Caller decides whether 0 means "pull controller's
  # full 7d retention" (backfill path) or "start fresh from now"
  # (normal incremental — controller filter handles the empty case).
  def self.last_ts_for(tenant_id)
    where(tenant_id: tenant_id).maximum(:ts_epoch) || 0
  end

  # ── Scopes ──────────────────────────────────────────────────────

  # range — narrows to a [from, to] window. ts_epoch is STORED, so
  # this is a pure integer comparison against the partial indexes.
  scope :range, ->(from:, to:) {
    where(ts_epoch: from.to_i..to.to_i).order(:ts_epoch)
  }

  # for_system — hits idx_metric_samples_system (partial WHERE source='system').
  scope :for_system, -> { where(source: "system") }

  # for_pod — hits idx_metric_samples_pod (partial WHERE source='pod').
  # `pod` is optional: omitting it widens the query to all replicas
  # of the same (scope, name) — the index covers the prefix.
  scope :for_pod, ->(scope:, name:, pod: nil) {
    rel = where(source: "pod", scope: scope, name: name)
    pod.present? ? rel.where(pod: pod) : rel
  }

  # ── Read accessors for JSON fields ──────────────────────────────
  #
  # The metric values live INSIDE the `payload` JSON (cpu_percent,
  # mem_usage_bytes, net_rx_delta_bytes, …) — not as columns. Callers
  # that need a specific metric across many rows should select with
  # `json_extract` directly in SQL for performance:
  #
  #   MetricSample.for_system.range(...)
  #     .pluck(Arel.sql("ts_iso, json_extract(payload, '$.cpu_percent')"))
  #
  # For a single-row lookup, `payload_json[key]` is fine:
  def payload_json
    @payload_json ||= JSON.parse(payload)
  rescue JSON::ParserError
    {}
  end
end
