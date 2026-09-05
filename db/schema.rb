# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_04_200100) do
  create_table "accounts", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "owner_id", null: false
    t.datetime "plan_activated_at"
    t.text "plan_license_token"
    t.string "short_id", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_id"], name: "index_accounts_on_owner_id"
    t.index ["short_id"], name: "index_accounts_on_short_id", unique: true
  end

  create_table "alert_destinations", force: :cascade do |t|
    t.text "body_template"
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.text "endpoint_ciphertext", null: false
    t.string "kind", null: false
    t.datetime "last_delivered_at"
    t.string "last_error"
    t.string "last_status"
    t.string "name", null: false
    t.boolean "on_firing", default: true, null: false
    t.boolean "on_resolved", default: true, null: false
    t.string "org_id", null: false
    t.text "secret_ciphertext"
    t.string "secret_header"
    t.datetime "updated_at", null: false
    t.index ["enabled"], name: "index_alert_destinations_on_server_id_and_enabled"
    t.index ["org_id", "name"], name: "index_alert_destinations_on_org_id_and_name", unique: true
  end

  create_table "alert_events", force: :cascade do |t|
    t.integer "alert_rule_id", null: false
    t.datetime "created_at", null: false
    t.float "last_value"
    t.string "metric_kind", null: false
    t.string "org_id", null: false
    t.float "peak_value"
    t.datetime "resolved_at"
    t.string "rule_name", null: false
    t.integer "server_id", null: false
    t.datetime "started_at", null: false
    t.string "state", default: "firing", null: false
    t.string "target_label", null: false
    t.float "threshold", null: false
    t.datetime "updated_at", null: false
    t.index ["alert_rule_id"], name: "index_alert_events_on_alert_rule_id"
    t.index ["alert_rule_id"], name: "index_alert_events_one_firing_per_rule", unique: true, where: "state = 'firing'"
    t.index ["org_id", "started_at"], name: "index_alert_events_on_org_id_and_started_at"
    t.index ["org_id", "state"], name: "index_alert_events_on_org_id_and_state"
    t.index ["server_id", "started_at"], name: "index_alert_events_on_server_id_and_started_at"
    t.index ["server_id", "state"], name: "index_alert_events_on_server_id_and_state"
    t.index ["server_id"], name: "index_alert_events_on_server_id"
  end

  create_table "alert_rule_destinations", force: :cascade do |t|
    t.integer "alert_destination_id", null: false
    t.integer "alert_rule_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["alert_destination_id"], name: "index_alert_rule_destinations_on_alert_destination_id"
    t.index ["alert_rule_id", "alert_destination_id"], name: "index_alert_rule_destinations_unique", unique: true
    t.index ["alert_rule_id"], name: "index_alert_rule_destinations_on_alert_rule_id"
  end

  create_table "alert_rules", force: :cascade do |t|
    t.string "comparator", default: "gte", null: false
    t.datetime "created_at", null: false
    t.integer "duration_seconds", default: 300, null: false
    t.boolean "enabled", default: true, null: false
    t.boolean "firing", default: false, null: false
    t.datetime "firing_since"
    t.datetime "last_evaluated_at"
    t.string "last_status"
    t.float "last_value"
    t.string "metric_kind", null: false
    t.string "name", null: false
    t.string "org_id", null: false
    t.integer "server_id", null: false
    t.string "target_kind", default: "host", null: false
    t.string "target_name"
    t.string "target_scope"
    t.float "threshold", null: false
    t.datetime "updated_at", null: false
    t.index ["org_id", "enabled"], name: "index_alert_rules_on_org_id_and_enabled"
    t.index ["server_id", "enabled"], name: "index_alert_rules_on_server_id_and_enabled"
    t.index ["server_id", "firing"], name: "index_alert_rules_on_server_id_and_firing"
    t.index ["server_id", "name"], name: "index_alert_rules_on_server_id_and_name", unique: true
    t.index ["server_id"], name: "index_alert_rules_on_server_id"
  end

  create_table "deployments", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "delivery_id"
    t.json "details", default: {}, null: false
    t.text "error"
    t.datetime "finished_at"
    t.integer "integration_id"
    t.string "org_id", null: false
    t.string "ref"
    t.string "remote_job_id"
    t.string "repo", null: false
    t.integer "server_id", null: false
    t.string "sha"
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.string "trigger_id"
    t.datetime "updated_at", null: false
    t.integer "webhook_receipt_id"
    t.index ["created_at"], name: "index_deployments_failed", where: "status = 'failed'"
    t.index ["integration_id"], name: "index_deployments_on_integration_id"
    t.index ["org_id", "created_at"], name: "index_deployments_on_org_id_and_created_at"
    t.index ["server_id", "created_at"], name: "index_deployments_on_server_id_and_created_at"
    t.index ["server_id", "delivery_id"], name: "index_deployments_on_delivery", unique: true, where: "delivery_id IS NOT NULL"
    t.index ["server_id", "repo", "created_at"], name: "index_deployments_on_serialization_key"
    t.index ["server_id"], name: "index_deployments_on_server_id"
    t.index ["started_at"], name: "index_deployments_running", where: "status = 'running'"
    t.index ["webhook_receipt_id"], name: "index_deployments_on_webhook_receipt_id"
  end

  create_table "integrations", force: :cascade do |t|
    t.json "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "external_id", null: false
    t.string "name"
    t.string "org_id", null: false
    t.string "provider", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["org_id", "provider", "external_id"], name: "index_integrations_on_org_id_and_provider_and_external_id", unique: true
    t.index ["provider", "external_id"], name: "index_integrations_on_provider_and_external_id"
  end

  create_table "metric_dashboards", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "org_id", null: false
    t.json "panels", default: [], null: false
    t.boolean "pinned", default: false, null: false
    t.datetime "updated_at", null: false
    t.string "uuid", null: false
    t.index ["org_id", "name"], name: "index_metric_dashboards_on_org_id_and_name", unique: true
    t.index ["org_id"], name: "index_metric_dashboards_one_pinned_per_org", unique: true, where: "pinned = true"
    t.index ["uuid"], name: "index_metric_dashboards_on_uuid", unique: true
  end

  create_table "ops_github_configs", force: :cascade do |t|
    t.string "configured_by_id"
    t.datetime "created_at", null: false
    t.text "private_key_ciphertext"
    t.string "provider", null: false
    t.json "settings", default: {}, null: false
    t.datetime "updated_at", null: false
    t.text "webhook_secret_ciphertext"
    t.index ["created_at"], name: "index_ops_github_configs_on_created_at"
  end

  create_table "ops_licenses", force: :cascade do |t|
    t.string "activated_by_id"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "issued_at", null: false
    t.datetime "last_checked_at"
    t.string "subject", null: false
    t.text "token", null: false
    t.datetime "updated_at", null: false
    t.index ["issued_at"], name: "index_ops_licenses_on_issued_at"
  end

  create_table "ops_sso_configs", force: :cascade do |t|
    t.string "configured_by_id"
    t.datetime "created_at", null: false
    t.datetime "migrated_at"
    t.string "pending_owner_email"
    t.string "provider", null: false
    t.text "secret_ciphertext"
    t.json "settings", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_ops_sso_configs_on_created_at"
  end

  create_table "org_memberships", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "invited_at"
    t.string "invited_by_id"
    t.string "org_id", null: false
    t.integer "role", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "user_id", null: false
    t.index ["invited_by_id"], name: "index_org_memberships_on_invited_by_id"
    t.index ["org_id"], name: "index_org_memberships_on_org_id"
    t.index ["user_id", "org_id"], name: "index_org_memberships_on_user_id_and_org_id", unique: true
  end

  create_table "org_server_accesses", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "membership_id", null: false
    t.string "org_id", null: false
    t.integer "server_id", null: false
    t.datetime "updated_at", null: false
    t.index ["membership_id", "server_id"], name: "index_org_server_accesses_on_membership_id_and_server_id", unique: true
    t.index ["server_id"], name: "index_org_server_accesses_on_server_id"
  end

  create_table "orgs", id: :string, force: :cascade do |t|
    t.string "account_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "short_id", null: false
    t.string "timezone"
    t.datetime "updated_at", null: false
    t.index ["account_id", "name"], name: "index_orgs_on_account_id_and_name", unique: true
    t.index ["account_id"], name: "index_orgs_on_account_id"
    t.index ["short_id"], name: "index_orgs_on_short_id", unique: true
  end

  create_table "pods", force: :cascade do |t|
    t.string "container_name", null: false
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.text "payload", null: false
    t.string "replica_id"
    t.string "resource_name", null: false
    t.string "scope", null: false
    t.integer "server_id", null: false
    t.datetime "synced_at", null: false
    t.datetime "updated_at", null: false
    t.index ["server_id", "container_name"], name: "index_pods_on_server_id_and_container_name", unique: true
    t.index ["server_id", "kind", "scope", "resource_name"], name: "index_pods_on_server_id_and_kind_and_scope_and_resource_name"
    t.index ["server_id"], name: "index_pods_on_server_id"
  end

  create_table "poller_digests", primary_key: "sync_hash", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_message"
    t.datetime "processed_at"
    t.integer "server_id", null: false
    t.string "status", default: "queued", null: false
    t.string "type", null: false
    t.index ["created_at"], name: "index_poller_digests_on_created_at"
    t.index ["server_id", "type", "created_at"], name: "index_poller_digests_on_server_id_and_type_and_created_at"
  end

  create_table "servers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "endpoint", null: false
    t.string "infra"
    t.string "key", null: false
    t.datetime "last_synced_at"
    t.string "name", null: false
    t.string "org_id", null: false
    t.text "pat_ciphertext", null: false
    t.string "region"
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_servers_on_key", unique: true
    t.index ["org_id", "name"], name: "index_servers_on_org_id_and_name", unique: true
    t.index ["org_id"], name: "index_servers_on_org_id"
  end

  create_table "settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "systems", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "payload", null: false
    t.integer "server_id", null: false
    t.datetime "synced_at", null: false
    t.datetime "updated_at", null: false
    t.index ["server_id"], name: "index_systems_on_server_id", unique: true
  end

  create_table "users", id: :string, force: :cascade do |t|
    t.string "avatar_url"
    t.string "clowk_provider"
    t.string "clowk_user_id"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.boolean "email_verified", default: false, null: false
    t.datetime "last_signed_in_at"
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["clowk_user_id"], name: "index_users_on_clowk_user_id", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  create_table "webhook_receipts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "details", default: {}, null: false
    t.string "event", null: false
    t.string "external_id"
    t.string "org_id"
    t.json "payload", default: {}, null: false
    t.string "provider", null: false
    t.datetime "received_at", null: false
    t.string "reference"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "external_id"], name: "index_webhook_receipts_on_delivery", unique: true, where: "external_id IS NOT NULL"
    t.index ["provider", "status", "received_at"], name: "index_webhook_receipts_on_provider_and_status_and_received_at"
    t.index ["received_at"], name: "index_webhook_receipts_on_received_at"
    t.index ["reference", "received_at"], name: "index_webhook_receipts_on_reference_and_received_at"
  end

  add_foreign_key "accounts", "users", column: "owner_id"
  add_foreign_key "alert_destinations", "orgs"
  add_foreign_key "alert_events", "alert_rules", on_delete: :cascade
  add_foreign_key "alert_events", "orgs"
  add_foreign_key "alert_events", "servers", on_delete: :cascade
  add_foreign_key "alert_rule_destinations", "alert_destinations", on_delete: :cascade
  add_foreign_key "alert_rule_destinations", "alert_rules", on_delete: :cascade
  add_foreign_key "alert_rules", "orgs"
  add_foreign_key "alert_rules", "servers", on_delete: :cascade
  add_foreign_key "deployments", "integrations"
  add_foreign_key "deployments", "orgs"
  add_foreign_key "deployments", "servers"
  add_foreign_key "metric_dashboards", "orgs"
  add_foreign_key "ops_licenses", "users", column: "activated_by_id", on_delete: :nullify
  add_foreign_key "ops_sso_configs", "users", column: "configured_by_id", on_delete: :nullify
  add_foreign_key "org_memberships", "orgs", on_delete: :cascade
  add_foreign_key "org_memberships", "users", column: "invited_by_id", on_delete: :nullify
  add_foreign_key "org_memberships", "users", on_delete: :cascade
  add_foreign_key "org_server_accesses", "org_memberships", column: "membership_id", on_delete: :cascade
  add_foreign_key "org_server_accesses", "orgs", on_delete: :cascade
  add_foreign_key "org_server_accesses", "servers", on_delete: :cascade
  add_foreign_key "orgs", "accounts"
  add_foreign_key "pods", "servers", on_delete: :cascade
  add_foreign_key "servers", "orgs"
  add_foreign_key "systems", "servers", on_delete: :cascade
end
