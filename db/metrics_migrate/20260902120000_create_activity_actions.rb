# frozen_string_literal: true

# Activity warehouse — ONE ROW PER ACTION, not per NDJSON line.
#
# The controller writes an append-only trail where a long action is two lines
# (`started`, then `finished`) and an instantaneous one is a single `done`. The
# screen is a datatable filtered by status — and status only exists on the line
# that CLOSES the pair. Keeping both lines as rows would make every filtered
# page load collapse the pair with a window function; merging them here makes
# it `WHERE status = 'failed'` against an index.
#
# The merge is an upsert keyed on the identity below, and it is why re-delivery
# is free: the poller may re-send a window it already sent (its watermark is
# in-memory and a restart reaches back), and re-applying the same lines lands
# on the same row.
#
# ## The identity: (server_id, activity_id, config_key)
#
# `activity_id` alone would be enough for apply / restart / delete / rollback.
# It is not enough for config: `vd config set A=1 B=2` writes one line PER KEY,
# all sharing one id, because the three of them came from one command and the
# trail should say so. Keyed on the id alone, the second key would overwrite
# the first and the screen would show one change where two happened.
#
# So the key is part of the identity, empty for every non-config action.
#
# ## Why the metrics DB and not a sixth one
#
# Low volume (dozens of rows a day per server, against thousands an hour for
# metrics) and the same writer — the poller. A dedicated database would buy
# isolation from a load that does not exist, and cost a fifth connection pool,
# a fifth schema file and a fifth thing to remember in `db:prepare`.
#
# ## Columns
#
# Real columns are the ones the WRITE path needs — the ingest builds them
# before it can decide what to do with the row. Everything else is generated
# from `payload`, so a field added to the controller's Record reaches the
# warehouse with no migration, exactly like metric_samples.
class CreateActivityActions < ActiveRecord::Migration[8.1]
  def change
    create_table :activity_actions do |t|
      t.integer :server_id, null: false

      # Identity. `config_key` is "" for non-config actions rather than NULL:
      # SQLite treats NULLs as distinct in a UNIQUE index, so a nullable column
      # here would let every re-delivered apply insert a second row.
      t.string :activity_id, null: false
      t.string :config_key, null: false, default: ""

      # `event` and `event_rank` drive the merge. The rank is a real column,
      # not generated, because the upsert's guard compares it against the
      # incoming row (`excluded.event_rank`) and a generated column is not
      # reliably readable there.
      #
      #   0 started — in flight
      #   1 finished — closed a pair
      #   2 done — instantaneous, terminal on arrival
      #
      # Higher wins. A re-delivered `started` arriving after the `finished`
      # must not revert the row to in-flight.
      t.integer :event_rank, null: false
      t.string :event, null: false

      t.string :action, null: false
      t.string :ts_iso, null: false
      t.text :payload, null: false

      # STORED for the same reason metric_samples stores it: range scans need
      # a column the planner can index, not an expression.
      t.virtual :ts_epoch, type: :integer,
        as: "CAST(strftime('%s', ts_iso) AS INTEGER)",
        stored: true

      # VIRTUAL — the filter and display fields, computed at read.
      t.virtual :origin, type: :string, as: "json_extract(payload, '$.origin')"
      t.virtual :actor, type: :string, as: "json_extract(payload, '$.actor')"
      t.virtual :scope, type: :string, as: "json_extract(payload, '$.scope')"
      t.virtual :kind, type: :string, as: "json_extract(payload, '$.kind')"
      t.virtual :name, type: :string, as: "json_extract(payload, '$.name')"
      t.virtual :status, type: :string, as: "json_extract(payload, '$.status')"
      t.virtual :release_id, type: :string, as: "json_extract(payload, '$.release_id')"
      t.virtual :elapsed_ms, type: :integer, as: "json_extract(payload, '$.elapsed_ms')"

      # No t.timestamps — ts_iso from the controller is the only time that
      # matters. "When did we ingest it" is not a question the screen asks.
    end

    # The merge key. Also the guard against the poller re-delivering a window.
    add_index :activity_actions, [:server_id, :activity_id, :config_key],
      unique: true,
      name: "idx_activity_actions_identity"

    # The default listing (newest first for one server) and the sync watermark
    # (MAX(ts_epoch) per server) are the same index.
    add_index :activity_actions, [:server_id, :ts_epoch],
      name: "idx_activity_actions_recent"

    # Filtered listings. Each puts ts_epoch rightmost so the filter narrows and
    # the order still comes off the index instead of a sort.
    add_index :activity_actions, [:server_id, :status, :ts_epoch],
      name: "idx_activity_actions_status"

    add_index :activity_actions, [:server_id, :action, :ts_epoch],
      name: "idx_activity_actions_action"

    add_index :activity_actions, [:server_id, :scope, :ts_epoch],
      name: "idx_activity_actions_scope"
  end
end
