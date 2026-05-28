# frozen_string_literal: true

# CreatePollerDigests — receipt + dedup table for the Go binary's
# "I dropped a digest folder, please process it" notifications.
#
# Wire shape:
#
#   Go binary writes storage/poller/<type>/<sync_hash>/ (NDJSON +
#   JSON files), then POSTs /internal/poller/digest with the
#   {type, tenant_id, sync_hash, ts, size} body. Rails inserts a
#   row here in `status=queued` and enqueues PollerDigestJob, which
#   walks the folder + persists snapshots/metrics + broadcasts.
#
# Note: this migration creates the column as `island_id`; a sibling
# migration (`20260528170000_rename_poller_digests_island_id_to_tenant_id.rb`)
# renames it to `tenant_id`. The runtime model/controller/services
# use `tenant_id` end-to-end — the naming follows the
# platform-internal "tenant" vocabulary (sibling of `tenant_key` in
# the URL routing) rather than the storage-side `island_id` used on
# pods/systems/log_exports.
#
# Why xxhash64 (16-hex) as the primary key:
#
#   - Idempotent re-deliveries are free: the Go binary can retry the
#     POST without coordinating "did Rails ack this?" — the second
#     INSERT hits the PK conflict and the controller short-circuits
#     to `{status: "duplicate"}` without re-enqueuing.
#   - The hash IS the folder name on disk, so the row, the job
#     payload, and the storage path all share one identifier.
#
# The `type` column is intentionally not enum-typed: model-side
# validation against PollerDigest::TYPES is enough, and string
# storage keeps the schema friendly to inspection (`sqlite3 .dump`
# shows readable values).
class CreatePollerDigests < ActiveRecord::Migration[8.1]
  def change
    create_table :poller_digests, id: false do |t|
      t.string   :sync_hash,     primary_key: true
      t.string   :type,          null: false
      t.integer  :island_id,     null: false
      t.string   :status,        null: false, default: "queued"
      t.text     :error_message
      t.datetime :processed_at
      t.datetime :created_at,    null: false
    end

    # Per-tenant recent-digest browsing (operator dashboard, debug
    # tooling). Composite index covers the most natural query —
    # "what did this tenant ship lately?" — without forcing a
    # full table scan as the table grows. (Column gets renamed to
    # `tenant_id` by the next migration; index is renamed alongside.)
    add_index :poller_digests, [:island_id, :type, :created_at]

    # Global age sweep — periodic cleanup of processed/failed digests
    # older than the retention window.
    add_index :poller_digests, :created_at
  end
end
