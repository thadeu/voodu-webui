class AddLastSyncedAtToIslands < ActiveRecord::Migration[8.1]
  def change
    # `last_synced_at` is touched by `StateSyncIslandJob` at the end of
    # every successful pods+system sync (inside the outer transaction
    # that wraps the snapshot replacements). Drives:
    #
    #   - Sidebar per-island "synced 8s ago" sub-text
    #   - IslandHealth status derivation (≤30s online,
    #     30–120s degraded, >120s offline)
    #   - Topbar `updated` chip when WAREHOUSE=1
    #
    # Nullable: brand-new islands haven't synced yet. UI renders "—"
    # in that window until the first sync completes (within 10s of
    # island creation, since `after_create_commit` also kicks the job).
    add_column :islands, :last_synced_at, :datetime
  end
end
