# frozen_string_literal: true

# Timezone is a per-org DISPLAY preference: every server-rendered timestamp
# for pods/metrics under an org reads this via WebTime (through Current.org).
# Nullable — a blank org timezone falls back to the global Setting, then UTC.
class AddTimezoneToOrgs < ActiveRecord::Migration[8.1]
  def change
    add_column :orgs, :timezone, :string
  end
end
