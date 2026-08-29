# frozen_string_literal: true

# `pinned = 1` is SQLite talking. Postgres stores this column as a real boolean
# and rejects comparing it to an integer, so db/schema.rb — the one file that
# has to load on BOTH adapters — could not be loaded into a fresh Postgres at
# all. `pinned = true` is accepted verbatim by each of them.
#
# Recreating the index is the whole change; the uniqueness it enforces (one
# pinned dashboard per org) is identical before and after.
#
# The two older migrations that spell it `pinned = 1` are deliberately left
# alone. They only ever run against a fresh SQLite database — a fresh Postgres
# loads db/schema.rb and assume_migrated_upto_version marks them applied
# without executing them — so editing applied migrations would buy nothing and
# risk a mismatch with databases that already ran them.
class MakePinnedIndexPredicatePortable < ActiveRecord::Migration[8.1]
  INDEX = "index_metric_dashboards_one_pinned_per_org"

  def up
    remove_index :metric_dashboards, name: INDEX
    add_index :metric_dashboards, :org_id, name: INDEX, unique: true, where: "pinned = true"
  end

  def down
    remove_index :metric_dashboards, name: INDEX
    add_index :metric_dashboards, :org_id, name: INDEX, unique: true, where: "pinned = 1"
  end
end
