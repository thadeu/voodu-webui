# frozen_string_literal: true

# orgs — the Org (server) layer above servers. An Org groups N servers
# (servers); Metrics + Alerts become org-level in later milestones. String
# primary key holding a UUIDv7 (see HasUuidV7 concern — SQLite has no uuid
# type, so we store TEXT and fill it app-side). `short_id` is the opaque
# 8-char handle for URLs from M1 on — generated now so it's ready.
class CreateOrgs < ActiveRecord::Migration[8.1]
  def change
    create_table :orgs, id: :string do |t|
      t.string :short_id, null: false
      t.string :name, null: false
      t.text :description

      t.timestamps
    end

    add_index :orgs, :short_id, unique: true
    add_index :orgs, :name, unique: true
  end
end
