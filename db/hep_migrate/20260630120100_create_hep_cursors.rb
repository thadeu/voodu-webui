# frozen_string_literal: true

# Hep3 poller watermark — one row per (server, reader instance). The
# voodu-hep3 /export endpoint reports its resume point as an opaque
# "<file>:<offset>" cursor in the X-Hep-Cursor header; we persist it so
# the next poll pulls strictly newer lines (no re-read, no duplicates).
#
# This is the HEP3 analogue of metric_samples' MAX(ts_epoch) watermark,
# except the boundary is the reader's cursor rather than a timestamp the
# read model can derive on its own.
class CreateHepCursors < ActiveRecord::Migration[8.1]
  def change
    create_table :hep_cursors do |t|
      t.integer :server_id, null: false
      t.string :scope, null: false
      t.string :name, null: false
      t.string :cursor, null: false, default: ""

      t.timestamps
    end

    add_index :hep_cursors, [:server_id, :scope, :name],
      unique: true, name: "idx_hep_cursors_instance"
  end
end
