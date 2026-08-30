# frozen_string_literal: true

# Tables follow their models into the Ops namespace, so the three layers line
# up: Ops::LicenseController → Ops::License → ops_licenses.
#
# The rename also removes a word that had stopped being true. `license_keys`
# was named when the row held little more than a token; it now holds the
# activation — who did it, when, and what it granted — and "key" described the
# smallest part of that.
class NamespaceOpsTables < ActiveRecord::Migration[8.1]
  def change
    rename_table :license_keys, :ops_licenses
    rename_table :sso_configurations, :ops_sso_configs
  end
end
