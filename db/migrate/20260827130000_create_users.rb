# frozen_string_literal: true

# users — the local mirror of a Clowk subject. Identity lives at Clowk; this
# row exists so orgs can be linked to a person, and holds nothing that is not
# already in the token.
#
# `clowk_user_id` is nullable AND unique on purpose. Postgres and SQLite both
# allow many NULLs in a unique index, so a row created by an invitation — a
# person who has never signed in and therefore has no `sub` yet — coexists with
# every bound row, while each bound row stays exclusive to one Clowk subject.
# That is what lets a first sign-in CLAIM an invited row instead of creating a
# duplicate identity beside it.
#
# `email_verified` is not decoration: invitations bind to an address, so an
# address nobody has proven is a way to be handed someone else's invitation.
# It defaults to false because a row that predates the claim carries an address
# we never checked.
class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users, id: :string do |t|
      t.string :clowk_user_id
      t.string :clowk_provider
      t.string :email, null: false
      t.boolean :email_verified, null: false, default: false
      t.string :name
      t.string :avatar_url
      t.datetime :last_signed_in_at

      t.timestamps
    end

    add_index :users, :clowk_user_id, unique: true
    add_index :users, :email, unique: true
  end
end
