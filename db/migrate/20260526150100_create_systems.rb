class CreateSystems < ActiveRecord::Migration[8.1]
  def change
    # systems — local snapshot of `/api/pat/v1/system` for one server.
    # Exactly one row per server, refreshed every 10s by
    # `StateSyncServerJob`. Topbar uptime chip + Overview host CPU/Mem
    # cards read from this row instead of making a fresh HTTP call.
    #
    # Mirrors the `pods` table's shape (JSON payload + synced_at) so
    # the sync job pattern is symmetric between runtime + host data.
    create_table :systems do |t|
      # has_one :system from Server side — unique server_id keeps the
      # ratio enforced at the DB layer too.
      t.references :server, null: false,
        foreign_key: {on_delete: :cascade},
        index: {unique: true}

      # The entire /system response as a JSON blob. Hot fields are NOT
      # extracted into separate columns yet — the topbar reads a single
      # row by server_id, so an extra index doesn't help, and keeping
      # the schema narrow means new /system fields (network, kernel
      # info, etc.) land here for free.
      t.text :payload, null: false

      # Timestamp of the controller fetch that produced this row.
      t.datetime :synced_at, null: false

      t.timestamps
    end
  end
end
