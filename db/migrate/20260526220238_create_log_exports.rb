# frozen_string_literal: true

# CreateLogExports — tracking row for each log export the operator
# requests. The actual file lives on disk under storage/exports/<id>;
# this table holds the job's state machine + the metadata the drawer
# UI surfaces (params used, file size, status, expiry).
#
# Rows + their on-disk files are reaped by LogExportCleanupJob after
# the `expires_at` window (default 24h post-ready).
class CreateLogExports < ActiveRecord::Migration[8.1]
  def change
    create_table :log_exports do |t|
      t.references :island, null: false, foreign_key: { on_delete: :cascade }

      # JSON blob: { from, until, pods, content_search, regex,
      # group_by_pod, format }. Stored as text for SQLite portability
      # (same idiom as MetricSample.payload + Pod#payload).
      t.text :params, null: false

      # State machine: queued → running → ready | failed
      t.string :status, null: false, default: "queued"

      # On-disk artifact location, relative to Rails.root. nil until
      # the job writes the file. Set to nil + removed from disk by
      # the cleanup job after expires_at.
      t.string :file_path

      # File size in bytes, for the UI to display "4.2 MB" without
      # statting the disk on every page render.
      t.bigint :file_size_bytes

      # Matched-line count when content_search is used; total line
      # count otherwise. Surfaces "Matched 1,234 lines" in the UI.
      t.integer :line_count

      # Free-form error message when status: failed. Shown in the
      # drawer alongside a Retry button.
      t.text :error

      # When the job finished writing the file (transition to :ready).
      t.datetime :ready_at

      # First time the operator clicked Download. Informational —
      # we still keep the file available until expires_at regardless,
      # so re-download from the drawer remains possible.
      t.datetime :downloaded_at

      # When the row + file get reaped. Default 24h post-ready, set
      # by LogExportJob on transition to :ready.
      t.datetime :expires_at

      t.timestamps
    end

    # Index on (island_id, created_at) for "recent exports for this
    # island" listings + the cleanup scan filtered by expires_at.
    add_index :log_exports, [:island_id, :created_at]
    add_index :log_exports, :expires_at
  end
end
