# frozen_string_literal: true

# Metric dashboards move from a single server up to the Org (M2): a dashboard
# now belongs to the org and each panel carries its own server_id (any server
# in the org). Uniqueness + the single-pinned constraint become per-ORG. DBs
# are wiped for this, so the table is empty when the column flips.
class MoveDashboardsToOrg < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :metric_dashboards, :servers
    remove_index :metric_dashboards, name: "index_metric_dashboards_on_server_id_and_name"
    remove_index :metric_dashboards, name: "index_metric_dashboards_one_pinned_per_server"
    remove_index :metric_dashboards, name: "index_metric_dashboards_on_server_id"
    remove_column :metric_dashboards, :server_id

    add_column :metric_dashboards, :org_id, :string, null: false
    add_index :metric_dashboards, [:org_id, :name], unique: true
    add_index :metric_dashboards, :org_id, unique: true, where: "pinned = 1",
      name: "index_metric_dashboards_one_pinned_per_org"
    add_foreign_key :metric_dashboards, :orgs, column: :org_id, primary_key: :id
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
