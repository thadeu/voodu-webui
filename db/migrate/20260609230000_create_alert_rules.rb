# frozen_string_literal: true

# Alert rules — operator-defined thresholds evaluated against the
# local metrics warehouse (no controller round-trip). One island has
# many; each rule targets either the host (source=system/ingress) or
# a pod workload (scope + resource name, same addressing the /metrics
# PodPicker uses).
#
# The firing/last_* columns cache the evaluator's verdict so the
# sidebar badge and the rules table render from one indexed read —
# the open AlertEvent row stays the source of truth for history.
class CreateAlertRules < ActiveRecord::Migration[8.1]
  def change
    create_table :alert_rules do |t|
      t.references :island, null: false, foreign_key: { on_delete: :cascade }
      t.string  :name,             null: false
      t.string  :metric_kind,      null: false
      t.string  :target_kind,      null: false, default: "host"
      t.string  :target_scope
      t.string  :target_name
      t.string  :comparator,       null: false, default: "gte"
      t.float   :threshold,        null: false
      t.integer :duration_seconds, null: false, default: 300
      t.boolean :enabled,          null: false, default: true

      t.boolean  :firing, null: false, default: false
      t.datetime :firing_since
      t.datetime :last_evaluated_at
      t.float    :last_value
      t.string   :last_status

      t.timestamps
    end

    add_index :alert_rules, [:island_id, :name], unique: true
    add_index :alert_rules, [:island_id, :enabled]
    add_index :alert_rules, [:island_id, :firing]
  end
end
