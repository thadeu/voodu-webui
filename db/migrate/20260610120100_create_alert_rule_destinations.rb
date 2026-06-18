# frozen_string_literal: true

# Join between rules and the destinations they notify. A rule with NO
# rows here notifies ALL enabled destinations (the "default = all"
# convention, mirroring the logs PodScopePicker's empty = all-pods).
# A rule with rows notifies exactly that subset.
class CreateAlertRuleDestinations < ActiveRecord::Migration[8.1]
  def change
    create_table :alert_rule_destinations do |t|
      t.references :alert_rule, null: false, foreign_key: {on_delete: :cascade}
      t.references :alert_destination, null: false, foreign_key: {on_delete: :cascade}
      t.timestamps
    end

    add_index :alert_rule_destinations, [:alert_rule_id, :alert_destination_id],
      unique: true, name: "index_alert_rule_destinations_unique"
  end
end
