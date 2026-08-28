# frozen_string_literal: true

# accounts — the signup tenant. One account groups N orgs; an org belongs to
# exactly one account.
#
# An account GROUPS and (later) BILLS. It does not authorize: sharing an
# account with someone grants them nothing, and reaching an org is always and
# only a membership. That is deliberate — a second path to "may I see this"
# is how the first cross-tenant leak gets written, and cross-account access
# (being invited into another company's org) then needs no exception at all.
#
# `owner_id` names the principal: the person who signed up, who cannot be
# removed by an admin, and who answers for the account. It is a fact about
# billing and responsibility, never a grant.
class CreateAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts, id: :string do |t|
      t.string :short_id, null: false
      t.string :name, null: false
      t.string :owner_id, null: false

      t.timestamps
    end

    add_index :accounts, :short_id, unique: true
    add_index :accounts, :owner_id
    # restrict: deleting a person who still answers for an account must fail
    # loudly rather than leave it ownerless.
    add_foreign_key :accounts, :users, column: :owner_id
  end
end
