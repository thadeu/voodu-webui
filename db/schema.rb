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

ActiveRecord::Schema[8.1].define(version: 2026_06_10_160000) do
  create_table "alert_destinations", force: :cascade do |t|
    t.text "body_template"
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.text "endpoint_ciphertext", null: false
    t.integer "island_id", null: false
    t.string "kind", null: false
    t.datetime "last_delivered_at"
    t.string "last_error"
    t.string "last_status"
    t.string "name", null: false
    t.boolean "on_firing", default: true, null: false
    t.boolean "on_resolved", default: true, null: false
    t.text "secret_ciphertext"
    t.string "secret_header"
    t.datetime "updated_at", null: false
    t.index ["island_id", "enabled"], name: "index_alert_destinations_on_island_id_and_enabled"
    t.index ["island_id", "name"], name: "index_alert_destinations_on_island_id_and_name", unique: true
    t.index ["island_id"], name: "index_alert_destinations_on_island_id"
  end

  create_table "alert_events", force: :cascade do |t|
    t.integer "alert_rule_id", null: false
    t.datetime "created_at", null: false
    t.integer "island_id", null: false
    t.float "last_value"
    t.string "metric_kind", null: false
    t.float "peak_value"
    t.datetime "resolved_at"
    t.string "rule_name", null: false
    t.datetime "started_at", null: false
    t.string "state", default: "firing", null: false
    t.string "target_label", null: false
    t.float "threshold", null: false
    t.datetime "updated_at", null: false
    t.index ["alert_rule_id"], name: "index_alert_events_on_alert_rule_id"
    t.index ["alert_rule_id"], name: "index_alert_events_one_firing_per_rule", unique: true, where: "state = 'firing'"
    t.index ["island_id", "started_at"], name: "index_alert_events_on_island_id_and_started_at"
    t.index ["island_id", "state"], name: "index_alert_events_on_island_id_and_state"
    t.index ["island_id"], name: "index_alert_events_on_island_id"
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
    t.integer "island_id", null: false
    t.datetime "last_evaluated_at"
    t.string "last_status"
    t.float "last_value"
    t.string "metric_kind", null: false
    t.string "name", null: false
    t.string "target_kind", default: "host", null: false
    t.string "target_name"
    t.string "target_scope"
    t.float "threshold", null: false
    t.datetime "updated_at", null: false
    t.index ["island_id", "enabled"], name: "index_alert_rules_on_island_id_and_enabled"
    t.index ["island_id", "firing"], name: "index_alert_rules_on_island_id_and_firing"
    t.index ["island_id", "name"], name: "index_alert_rules_on_island_id_and_name", unique: true
    t.index ["island_id"], name: "index_alert_rules_on_island_id"
  end

  create_table "islands", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "endpoint", null: false
    t.string "infra"
    t.string "key", null: false
    t.datetime "last_synced_at"
    t.string "name", null: false
    t.text "pat_ciphertext", null: false
    t.string "region"
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_islands_on_key", unique: true
    t.index ["name"], name: "index_islands_on_name", unique: true
  end

  create_table "metric_dashboards", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "island_id", null: false
    t.string "name", null: false
    t.json "panels", default: [], null: false
    t.boolean "pinned", default: false, null: false
    t.datetime "updated_at", null: false
    t.string "uuid", null: false
    t.index ["island_id", "name"], name: "index_metric_dashboards_on_island_id_and_name", unique: true
    t.index ["island_id"], name: "index_metric_dashboards_on_island_id"
    t.index ["island_id"], name: "index_metric_dashboards_one_pinned_per_island", unique: true, where: "pinned = 1"
    t.index ["uuid"], name: "index_metric_dashboards_on_uuid", unique: true
  end

  create_table "pods", force: :cascade do |t|
    t.string "container_name", null: false
    t.datetime "created_at", null: false
    t.integer "island_id", null: false
    t.string "kind", null: false
    t.text "payload", null: false
    t.string "replica_id"
    t.string "resource_name", null: false
    t.string "scope", null: false
    t.datetime "synced_at", null: false
    t.datetime "updated_at", null: false
    t.index ["island_id", "container_name"], name: "index_pods_on_island_id_and_container_name", unique: true
    t.index ["island_id", "kind", "scope", "resource_name"], name: "index_pods_on_island_id_and_kind_and_scope_and_resource_name"
    t.index ["island_id"], name: "index_pods_on_island_id"
  end

  create_table "poller_digests", primary_key: "sync_hash", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_message"
    t.datetime "processed_at"
    t.string "status", default: "queued", null: false
    t.integer "tenant_id", null: false
    t.string "type", null: false
    t.index ["created_at"], name: "index_poller_digests_on_created_at"
    t.index ["tenant_id", "type", "created_at"], name: "index_poller_digests_on_tenant_id_and_type_and_created_at"
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
    t.integer "island_id", null: false
    t.text "payload", null: false
    t.datetime "synced_at", null: false
    t.datetime "updated_at", null: false
    t.index ["island_id"], name: "index_systems_on_island_id", unique: true
  end

  add_foreign_key "alert_destinations", "islands", on_delete: :cascade
  add_foreign_key "alert_events", "alert_rules", on_delete: :cascade
  add_foreign_key "alert_events", "islands", on_delete: :cascade
  add_foreign_key "alert_rule_destinations", "alert_destinations", on_delete: :cascade
  add_foreign_key "alert_rule_destinations", "alert_rules", on_delete: :cascade
  add_foreign_key "alert_rules", "islands", on_delete: :cascade
  add_foreign_key "metric_dashboards", "islands", on_delete: :cascade
  add_foreign_key "pods", "islands", on_delete: :cascade
  add_foreign_key "systems", "islands", on_delete: :cascade
end
