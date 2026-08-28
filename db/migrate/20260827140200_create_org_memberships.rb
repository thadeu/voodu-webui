# frozen_string_literal: true

# org_memberships — the ONLY thing that grants access to an org.
#
# An invitation is a membership with `status: invited`; there is no separate
# invitations table. That removes a whole duplicate-identity surface: no second
# place holding an email address, no token column to leak, no way for an
# invitation and a membership to disagree about who someone is.
#
# `role` is ordered (member < admin < owner) so a capability check is a
# comparison rather than a list repeated at each call site — see Permissions.
class CreateOrgMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :org_memberships, id: :string do |t|
      t.string :user_id, null: false
      t.string :org_id, null: false
      t.integer :role, null: false, default: 0
      t.integer :status, null: false, default: 0
      t.datetime :invited_at

      t.timestamps
    end

    add_index :org_memberships, [:user_id, :org_id], unique: true
    add_index :org_memberships, :org_id
    add_foreign_key :org_memberships, :users, on_delete: :cascade
    add_foreign_key :org_memberships, :orgs, on_delete: :cascade
  end
end
