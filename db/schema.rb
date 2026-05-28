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

ActiveRecord::Schema[8.1].define(version: 2026_05_28_170000) do
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

  create_table "log_exports", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "downloaded_at"
    t.text "error"
    t.datetime "expires_at"
    t.string "file_path"
    t.bigint "file_size_bytes"
    t.integer "island_id", null: false
    t.integer "line_count"
    t.text "params", null: false
    t.datetime "ready_at"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_log_exports_on_expires_at"
    t.index ["island_id", "created_at"], name: "index_log_exports_on_island_id_and_created_at"
    t.index ["island_id"], name: "index_log_exports_on_island_id"
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

  add_foreign_key "log_exports", "islands", on_delete: :cascade
  add_foreign_key "pods", "islands", on_delete: :cascade
  add_foreign_key "systems", "islands", on_delete: :cascade
end
