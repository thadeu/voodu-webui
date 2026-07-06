# frozen_string_literal: true

# Move the alert subsystem to the org (M3, mirrors the M2 dashboard move).
#
#   - alert_rules      → add org_id (owner). KEEP server_id — it's the TARGET
#                        server the rule monitors (a rule targets exactly one
#                        server in its org). Name stays unique per target server.
#   - alert_destinations → org-shared notification targets: add org_id, DROP
#                        server_id (a webhook belongs to the org, not one server).
#   - alert_events     → add org_id (owner, for the org-level history/firing
#                        query). KEEP server_id — the server the episode fired on.
#
# Nothing in production → no data backfill; org_id is added null:false directly.
class MoveAlertsToOrg < ActiveRecord::Migration[8.1]
  def up
    # ── alert_rules ──────────────────────────────────────────────────
    add_column :alert_rules, :org_id, :string, null: false
    add_index :alert_rules, [:org_id, :enabled], name: "index_alert_rules_on_org_id_and_enabled"
    add_foreign_key :alert_rules, :orgs, column: :org_id

    # ── alert_destinations → org-level ───────────────────────────────
    remove_foreign_key :alert_destinations, :servers if foreign_key_exists?(:alert_destinations, :servers)
    remove_index :alert_destinations, name: "index_alert_destinations_on_server_id_and_name" if index_exists?(:alert_destinations, [:server_id, :name], name: "index_alert_destinations_on_server_id_and_name")
    remove_index :alert_destinations, column: :server_id if index_exists?(:alert_destinations, :server_id)
    remove_column :alert_destinations, :server_id

    add_column :alert_destinations, :org_id, :string, null: false
    add_index :alert_destinations, [:org_id, :name], unique: true, name: "index_alert_destinations_on_org_id_and_name"
    add_foreign_key :alert_destinations, :orgs, column: :org_id

    # ── alert_events ─────────────────────────────────────────────────
    add_column :alert_events, :org_id, :string, null: false
    add_index :alert_events, [:org_id, :state], name: "index_alert_events_on_org_id_and_state"
    add_index :alert_events, [:org_id, :started_at], name: "index_alert_events_on_org_id_and_started_at"
    add_foreign_key :alert_events, :orgs, column: :org_id
  end

  def down
    remove_foreign_key :alert_events, :orgs
    remove_column :alert_events, :org_id

    remove_foreign_key :alert_destinations, :orgs
    remove_column :alert_destinations, :org_id
    add_column :alert_destinations, :server_id, :integer, null: false
    add_index :alert_destinations, [:server_id, :name], unique: true, name: "index_alert_destinations_on_server_id_and_name"
    add_foreign_key :alert_destinations, :servers, column: :server_id

    remove_foreign_key :alert_rules, :orgs
    remove_column :alert_rules, :org_id
  end
end
