# frozen_string_literal: true

# Handing the existing workspace to a Clowk identity is now a two-step move:
# stated when sign-in is turned on, CONFIRMED after that person has actually
# signed in.
#
# The one-step version renamed the local operator immediately, which meant a
# wrong publishable key left the operator renamed AND locked out. Nothing is
# touched now until a real login proves the credentials work.
class AddMigrationToAuthConfigs < ActiveRecord::Migration[8.1]
  def change
    # Who may claim the workspace. Only this address is offered the migration,
    # or anyone who managed to sign in could take it.
    add_column :auth_configs, :pending_owner_email, :string
    add_column :auth_configs, :migrated_at, :datetime
  end
end
