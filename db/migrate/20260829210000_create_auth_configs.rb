# frozen_string_literal: true

# Clowk settings entered through the UI, so turning on real sign-in does not
# mean editing env vars and restarting.
#
# One row per change, like license_keys: the history is nearly free and answers
# "who turned this on, and when" — which for an authentication change is worth
# more than for most things.
class CreateAuthConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :auth_configs do |t|
      t.string :publishable_key, null: false
      t.string :subdomain_url
      # Encrypted: only needed for legacy HS256 tokens and the management API,
      # and it signs on behalf of the whole instance if it leaks.
      t.text :secret_key_ciphertext
      t.string :configured_by_id

      t.timestamps
    end

    add_index :auth_configs, :created_at
    add_foreign_key :auth_configs, :users, column: :configured_by_id, on_delete: :nullify
  end
end
