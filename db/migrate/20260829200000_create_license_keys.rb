# frozen_string_literal: true

# Where an activated licence lives, so renewing is pasting a token into Settings
# rather than editing an env var and restarting a monitoring dashboard.
#
# One row per activation rather than one row overwritten: the history is worth
# almost nothing to the product and quite a lot to a support conversation about
# when a customer upgraded and who did it. The active licence is simply the one
# with the newest issued_at.
class CreateLicenseKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :license_keys do |t|
      t.text :token, null: false
      t.string :subject, null: false
      # From the token's own iat/exp, denormalised so Settings and the daily
      # check can read them without verifying a signature first.
      t.datetime :issued_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :last_checked_at
      t.string :activated_by_id

      t.timestamps
    end

    # "the newest activation" is the only read that matters on the hot path.
    add_index :license_keys, :issued_at
    add_foreign_key :license_keys, :users, column: :activated_by_id, on_delete: :nullify
  end
end
