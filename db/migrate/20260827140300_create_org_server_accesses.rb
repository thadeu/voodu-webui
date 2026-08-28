# frozen_string_literal: true

# org_server_accesses — which servers a `member` reaches inside an org.
# Consulted only for that role; admin and owner reach every server in the org.
#
# `org_id` is NOT decoration. Without it the table permits a row pairing one
# org's membership with another org's server, and the natural query —
# `membership.server_accesses.select(:server_id)` — FEELS scoped because you
# arrived through the membership, but is not. The read is therefore written as
# `org.servers.where(id: …)` so the org scope applies twice and a bad row is
# inert; this column plus the model validation is what stops the row existing
# in the first place.
#
# Both FKs cascade. `servers.id` is a SQLite rowid and rowids are REUSED: delete
# the highest-id server, register a new one, and it inherits the id — so a grant
# that outlived its server would silently apply to whatever took its place.
class CreateOrgServerAccesses < ActiveRecord::Migration[8.1]
  def change
    create_table :org_server_accesses, id: :string do |t|
      t.string :membership_id, null: false
      t.integer :server_id, null: false
      t.string :org_id, null: false

      t.timestamps
    end

    add_index :org_server_accesses, [:membership_id, :server_id], unique: true
    add_index :org_server_accesses, :server_id
    add_foreign_key :org_server_accesses, :org_memberships, column: :membership_id, on_delete: :cascade
    add_foreign_key :org_server_accesses, :servers, on_delete: :cascade
    add_foreign_key :org_server_accesses, :orgs, on_delete: :cascade
  end
end
