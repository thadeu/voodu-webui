# frozen_string_literal: true

# Alert events — one row per firing episode (fire → resolve). Rule
# attributes are snapshotted at fire time (rule_name, metric_kind,
# target_label, threshold) so history rows render without joins and
# stay truthful after the rule is edited. island_id is denormalized
# for the same reason: badge counts and the history list never need
# the rules table.
class CreateAlertEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :alert_events do |t|
      t.references :alert_rule, null: false, foreign_key: { on_delete: :cascade }
      t.references :island,     null: false, foreign_key: { on_delete: :cascade }
      t.string   :state,        null: false, default: "firing"
      t.datetime :started_at,   null: false
      t.datetime :resolved_at
      t.float    :threshold,    null: false
      t.string   :rule_name,    null: false
      t.string   :metric_kind,  null: false
      t.string   :target_label, null: false
      t.float    :peak_value
      t.float    :last_value

      t.timestamps
    end

    add_index :alert_events, [:island_id, :state]
    add_index :alert_events, [:island_id, :started_at]

    # At most ONE open episode per rule. The evaluator checks
    # rule.firing first, but if two evaluation jobs ever overlap the
    # second insert raises RecordNotUnique instead of double-firing.
    add_index :alert_events, :alert_rule_id, unique: true,
              where: "state = 'firing'",
              name: "index_alert_events_one_firing_per_rule"
  end
end
