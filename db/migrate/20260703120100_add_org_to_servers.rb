# frozen_string_literal: true

# Every server (server) belongs to exactly one Org — a UUIDv7 string FK to
# orgs.id. null:false: no orphan servers (the registration form always
# picks or creates an org). DBs are wiped for this change, so the non-null
# column lands on an empty table. The FK restricts deleting an org that
# still owns servers (mirrored by a friendly model-level guard on Org).
class AddOrgToServers < ActiveRecord::Migration[8.1]
  def change
    add_column :servers, :org_id, :string, null: false
    add_index :servers, :org_id
    add_foreign_key :servers, :orgs, column: :org_id, primary_key: :id
  end
end
