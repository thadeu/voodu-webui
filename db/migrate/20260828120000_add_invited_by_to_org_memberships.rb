# frozen_string_literal: true

# Who issued an invitation.
#
# An invitation grants access to a tenant's infrastructure, and until now the
# row said only that someone had been asked — not by whom. When an unexpected
# person turns up in an org, "who let them in" is the first question, and the
# answer was nowhere.
#
# Nullable: rows that predate this, and the owner membership onboarding creates
# for itself, were invited by nobody. on_delete: :nullify rather than cascade —
# removing the admin who sent an invitation must not remove the person they
# invited.
class AddInvitedByToOrgMemberships < ActiveRecord::Migration[8.1]
  def change
    add_column :org_memberships, :invited_by_id, :string
    add_index :org_memberships, :invited_by_id
    add_foreign_key :org_memberships, :users, column: :invited_by_id, on_delete: :nullify
  end
end
