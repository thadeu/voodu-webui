# frozen_string_literal: true

# CreateSettings — key/value bucket for operator-global preferences.
#
# Generic on purpose: today's payload is just `timezone` (the IANA
# zone name the operator wants every server-rendered timestamp
# translated into). Tomorrow's might be refresh cadence, theme,
# default range pill, etc. A single table with one row per key
# avoids a migration each time a new pref shows up.
#
# Scope is operator-wide (NOT per-island) — Voodu webui is a
# single-tenant operator console, so global prefs make sense
# anchored to the install rather than to one of N managed servers.
class CreateSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :settings do |t|
      t.string :key, null: false
      t.text :value
      t.timestamps
    end

    add_index :settings, :key, unique: true
  end
end
