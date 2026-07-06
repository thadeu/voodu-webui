class AddLastSyncedAtToServers < ActiveRecord::Migration[8.1]
  def change
    # `last_synced_at` is touched by `StateSyncServerJob` at the end of
    # every successful pods+system sync (inside the outer transaction
    # that wraps the snapshot replacements). Drives:
    #
    #   - Sidebar per-server "synced 8s ago" sub-text
    #   - ServerHealth status derivation (≤30s online,
    #     30–120s degraded, >120s offline)
    #   - Topbar `updated` chip when WAREHOUSE=1
    #
    # Nullable: brand-new servers haven't synced yet. UI renders "—"
    # in that window until the first sync completes (within 10s of
    # server creation, since `after_create_commit` also kicks the job).
    add_column :servers, :last_synced_at, :datetime
  end
end
