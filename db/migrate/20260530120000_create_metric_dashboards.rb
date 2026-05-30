# frozen_string_literal: true

# Metric dashboards — operator-saved collections of (source, metric)
# panels rendered together on /metrics with a shared range + interval.
# One island has many; a single one may be pinned (the default view
# /metrics opens to). Panels ride in a native JSON column so the shape
# can evolve without a migration per field.
class CreateMetricDashboards < ActiveRecord::Migration[8.1]
  def change
    create_table :metric_dashboards do |t|
      t.references :island, null: false, foreign_key: { on_delete: :cascade }
      t.string  :name,   null: false
      t.json    :panels, null: false, default: []
      t.boolean :pinned, null: false, default: false
      t.timestamps
    end

    add_index :metric_dashboards, [:island_id, :name], unique: true

    # At most one pinned dashboard per island. The model's pin! also
    # enforces this transactionally; the partial unique index is the
    # DB-level backstop against a concurrent double-pin.
    add_index :metric_dashboards, :island_id, unique: true,
              where: "pinned = 1",
              name: "index_metric_dashboards_one_pinned_per_island"
  end
end
