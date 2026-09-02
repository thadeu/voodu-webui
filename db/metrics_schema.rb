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

ActiveRecord::Schema[8.1].define(version: 2026_09_02_120000) do
  create_table "activity_actions", force: :cascade do |t|
    t.string "action", null: false
    t.string "activity_id", null: false
    t.virtual "actor", type: :string, as: "json_extract(payload, '$.actor')", stored: false
    t.string "config_key", default: "", null: false
    t.virtual "elapsed_ms", type: :integer, as: "json_extract(payload, '$.elapsed_ms')", stored: false
    t.string "event", null: false
    t.integer "event_rank", null: false
    t.virtual "kind", type: :string, as: "json_extract(payload, '$.kind')", stored: false
    t.virtual "name", type: :string, as: "json_extract(payload, '$.name')", stored: false
    t.virtual "origin", type: :string, as: "json_extract(payload, '$.origin')", stored: false
    t.text "payload", null: false
    t.virtual "release_id", type: :string, as: "json_extract(payload, '$.release_id')", stored: false
    t.virtual "scope", type: :string, as: "json_extract(payload, '$.scope')", stored: false
    t.integer "server_id", null: false
    t.virtual "status", type: :string, as: "json_extract(payload, '$.status')", stored: false
    t.virtual "ts_epoch", type: :integer, as: "CAST(strftime('%s', ts_iso) AS INTEGER)", stored: true
    t.string "ts_iso", null: false
    t.index ["server_id", "action", "ts_epoch"], name: "idx_activity_actions_action"
    t.index ["server_id", "activity_id", "config_key"], name: "idx_activity_actions_identity", unique: true
    t.index ["server_id", "scope", "ts_epoch"], name: "idx_activity_actions_scope"
    t.index ["server_id", "status", "ts_epoch"], name: "idx_activity_actions_status"
    t.index ["server_id", "ts_epoch"], name: "idx_activity_actions_recent"
  end

  create_table "metric_samples", force: :cascade do |t|
    t.virtual "name", type: :string, as: "json_extract(payload, '$.name')", stored: false
    t.text "payload", null: false
    t.virtual "pod", type: :string, as: "json_extract(payload, '$.container')", stored: false
    t.virtual "scope", type: :string, as: "json_extract(payload, '$.scope')", stored: false
    t.integer "server_id", null: false
    t.string "source", null: false
    t.virtual "ts_epoch", type: :integer, as: "CAST(strftime('%s', ts_iso) AS INTEGER)", stored: true
    t.string "ts_iso", null: false
    t.index ["server_id", "source", "scope", "name", "pod", "ts_epoch"], name: "idx_metric_samples_pod", where: "source = 'pod'"
    t.index ["server_id", "source", "ts_epoch"], name: "idx_metric_samples_system", where: "source = 'system'"
    t.index ["server_id", "ts_epoch"], name: "idx_metric_samples_watermark"
  end
end
