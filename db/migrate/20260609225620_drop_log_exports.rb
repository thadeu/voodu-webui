# frozen_string_literal: true

# DropLogExports — the async log-export feature (LogExport / LogExportJob
# / ExportsController / the export drawer) was removed once the
# /logs/analytics surface gained its own synchronous copy/download
# export. This drops the now-unused table. `down` recreates it (mirroring
# the original CreateLogExports) so the migration is reversible; the rows
# were transient artifact-tracking metadata (24h TTL), nothing durable.
class DropLogExports < ActiveRecord::Migration[8.1]
  def up
    drop_table :log_exports
  end

  def down
    create_table :log_exports do |t|
      t.references :server, null: false, foreign_key: {on_delete: :cascade}
      t.text :params, null: false
      t.string :status, null: false, default: "queued"
      t.string :file_path
      t.bigint :file_size_bytes
      t.integer :line_count
      t.text :error
      t.datetime :ready_at
      t.datetime :downloaded_at
      t.datetime :expires_at
      t.timestamps
    end

    add_index :log_exports, [:server_id, :created_at]
    add_index :log_exports, :expires_at
  end
end
