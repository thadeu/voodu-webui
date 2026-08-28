# frozen_string_literal: true

# Server names are unique PER ORG, not globally.
#
# A global unique index turns the validation error into an enumeration oracle:
# type a guessed name, read "has already been taken", and you have learned that
# another tenant runs a server by that name. It also makes a perfectly ordinary
# collision — two customers both calling a box "web-1" — into a registration
# failure that the second one cannot explain or fix.
#
# `alert_destinations` already models it this way (index_alert_destinations_on
# _org_id_and_name); this brings servers in line.
class ScopeServerNameToOrg < ActiveRecord::Migration[8.1]
  def change
    remove_index :servers, :name, unique: true
    add_index :servers, [:org_id, :name], unique: true
  end
end
