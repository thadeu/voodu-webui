# frozen_string_literal: true

# Every org belongs to an account. NOT NULL from the start — this is a
# greenfield change (staging only, and db/migrate/20260703120100 set the
# precedent that DBs are wiped for structural moves), so there is no backfill
# and no nullable interim to forget to close.
#
# org names become unique PER ACCOUNT for the same reason server names became
# unique per org: a global index answers "has already been taken" for a name
# only another tenant uses.
class AddAccountToOrgs < ActiveRecord::Migration[8.1]
  def change
    add_column :orgs, :account_id, :string, null: false
    add_index :orgs, :account_id
    add_foreign_key :orgs, :accounts

    remove_index :orgs, :name, unique: true
    add_index :orgs, [:account_id, :name], unique: true
  end
end
