# frozen_string_literal: true

# The table was shaped around one provider.
#
# `publishable_key` and `subdomain_url` are Clowk's words, so adding a second
# provider would have meant either columns that are null for everyone who does
# not use Clowk, or a second table saying the same thing differently. The route
# and the controller are already provider-neutral (Ops::SsoController); this is
# the schema catching up.
#
# Settings move into JSON because nothing queries them: they are read whole and
# handed to whichever provider they configure. That is the opposite call from
# the metrics warehouse, where the generated columns exist precisely to be
# indexed and had to become real columns — the shape follows how the data is
# read, not a preference for one or the other.
#
# The secret stays its own encrypted column rather than joining the JSON. It is
# the only sensitive field, and burying it in the blob would mean encrypting the
# publishable key too — decrypting on every request to read something public.
class RenameAuthConfigsToSsoConfigurations < ActiveRecord::Migration[8.1]
  def up
    rename_table :auth_configs, :sso_configurations

    add_column :sso_configurations, :provider, :string
    add_column :sso_configurations, :settings, :json, default: {}, null: false

    # Fold the Clowk-shaped columns into the neutral pair.
    execute(<<~SQL.squish)
      UPDATE sso_configurations
         SET provider = 'clowk'
       WHERE provider IS NULL
    SQL

    SsoBackfill.reset_column_information
    SsoBackfill.find_each do |row|
      row.update_columns(settings: {
        "publishable_key" => row.publishable_key,
        "subdomain_url" => row.subdomain_url
      }.compact)
    end

    change_column_null :sso_configurations, :provider, false
    remove_column :sso_configurations, :publishable_key
    remove_column :sso_configurations, :subdomain_url

    rename_column :sso_configurations, :secret_key_ciphertext, :secret_ciphertext
  end

  def down
    rename_column :sso_configurations, :secret_ciphertext, :secret_key_ciphertext
    add_column :sso_configurations, :publishable_key, :string
    add_column :sso_configurations, :subdomain_url, :string

    SsoBackfill.reset_column_information
    SsoBackfill.find_each do |row|
      row.update_columns(
        publishable_key: row.settings["publishable_key"],
        subdomain_url: row.settings["subdomain_url"]
      )
    end

    remove_column :sso_configurations, :provider
    remove_column :sso_configurations, :settings
    rename_table :sso_configurations, :auth_configs
  end

  # A local model, because the real one has validations and encryption that
  # describe the schema AFTER this migration — using it here would break the
  # moment the app changes again.
  class SsoBackfill < ActiveRecord::Base
    self.table_name = "sso_configurations"
  end
end
