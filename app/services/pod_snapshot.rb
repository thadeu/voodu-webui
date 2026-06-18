# frozen_string_literal: true

# PodSnapshot — the service that takes the controller's
# `/pods?detail=true&spec=true` response and atomically replaces the
# `pods` table's row set for one island.
#
# Sibling of `SystemSnapshot`; together they are the only two writers
# of snapshot data. Called from `StateSyncIslandJob` every 10s.
#
# Atomicity model:
#
#   ActiveRecord::Base.transaction do
#     Pod.where(island_id: …).delete_all
#     Pod.insert_all(rows)
#   end
#
# SQLite in WAL mode (Rails 8 default) guarantees that concurrent
# readers see EITHER the pre-transaction row set OR the post-
# transaction row set — never the empty middle. This is what
# unlocks "delete-and-bulk-insert" as a clean abstraction without
# the UI flickering pods off and back on during each sync.
#
# When called inside an OUTER transaction (the job wraps both
# services + the `island.last_synced_at` touch together), Rails
# turns this inner one into a savepoint — pods/system/synced_at
# still commit-or-rollback as a unit. No semantic change vs
# standalone use.
#
# Input shape: `pods_payload` is the array returned in
# `data.pods` of the controller's response — an Array of Hashes,
# each with at least the keys this service reads from. The full
# hash is round-tripped to JSON and stored in `payload` so
# downstream readers don't lose any field.
class PodSnapshot
  # replace_for_island! — atomic swap of every pod snapshot for
  # one island. Returns the count of rows inserted.
  #
  # `pods_payload` accepts:
  #   - Array of Hash (typical: parsed JSON from the controller)
  #   - nil / empty (sync got back zero pods → just truncate the
  #     existing rows for this island; valid state for a freshly-
  #     joined-then-emptied host)
  def self.replace_for_island!(island, pods_payload)
    rows = build_rows(island, pods_payload)

    ActiveRecord::Base.transaction do
      Pod.where(island_id: island.id).delete_all

      # `insert_all` skips ActiveRecord callbacks + validations —
      # exactly what we want here (the model is read-only; the
      # sync job is the source of truth). With the unique index
      # `(island_id, container_name)` in place, the bulk insert
      # is also dedup-safe at the DB layer if the controller ever
      # ships duplicates.
      Pod.insert_all(rows) if rows.any?
    end

    rows.size
  end

  # ── Private helpers ────────────────────────────────────────────

  # build_rows — turn each pod hash into the ActiveRecord row shape
  # `insert_all` expects (no associations, no objects — just the
  # column → value map). Hot fields are extracted out so indexed
  # queries don't need to parse the JSON; the full hash is also
  # stored in `payload` for the read-side accessors on the Pod
  # model.
  #
  # Defensive dedup by container_name: docker enforces uniqueness on
  # the host, but if the controller ever produces duplicates (race
  # between list and inspect during a restart, etc.), `insert_all`
  # would raise on the unique index. Keep the last occurrence —
  # newer info shadows older.
  def self.build_rows(island, pods_payload)
    now = Time.current
    seen = {}

    Array(pods_payload).each do |pod|
      name = pod["name"].to_s
      next if name.empty?

      seen[name] = {
        island_id: island.id,
        container_name: name,
        kind: pod["kind"].to_s,
        scope: pod["scope"].to_s,
        resource_name: pod["resource_name"].to_s,
        replica_id: pod["replica_id"].presence,
        payload: pod.to_json,
        synced_at: now,
        created_at: now,
        updated_at: now
      }
    end

    seen.values
  end

  private_class_method :build_rows
end
