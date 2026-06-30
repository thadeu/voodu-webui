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

ActiveRecord::Schema[8.1].define(version: 2026_06_30_120100) do
  create_table "hep_cursors", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "cursor", default: "", null: false
    t.string "name", null: false
    t.string "scope", null: false
    t.integer "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "scope", "name"], name: "idx_hep_cursors_instance", unique: true
  end

  create_table "hep_messages", force: :cascade do |t|
    t.virtual "call_id", type: :string, as: "json_extract(payload, '$.call_id')", stored: false
    t.virtual "corr_id", type: :string, as: "COALESCE(NULLIF(json_extract(payload, '$.x_cid'), ''), json_extract(payload, '$.call_id'))", stored: false
    t.string "name", null: false
    t.text "payload", null: false
    t.virtual "response_code", type: :integer, as: "json_extract(payload, '$.response_code')", stored: false
    t.string "scope", null: false
    t.virtual "sip_method", type: :string, as: "json_extract(payload, '$.method')", stored: false
    t.integer "tenant_id", null: false
    t.virtual "ts", type: :string, as: "json_extract(payload, '$.ts')", stored: false
    t.virtual "ts_epoch", type: :integer, as: "CAST(strftime('%s', json_extract(payload, '$.ts')) AS INTEGER)", stored: true
    t.virtual "x_cid", type: :string, as: "json_extract(payload, '$.x_cid')", stored: false
    t.index ["tenant_id", "call_id"], name: "idx_hep_messages_call_id"
    t.index ["tenant_id", "scope", "name", "corr_id", "ts_epoch"], name: "idx_hep_messages_call"
    t.index ["tenant_id", "scope", "name", "ts_epoch"], name: "idx_hep_messages_recent"
  end
end
