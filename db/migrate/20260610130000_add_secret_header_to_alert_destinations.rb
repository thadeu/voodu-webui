# frozen_string_literal: true

# A generic webhook may need an arbitrary auth header — the name
# varies by provider (Authorization, x-api-key, x-zapier-key, …) and
# the value carries the scheme/token (Bearer …, Token token="…", a
# bare key). secret_ciphertext already holds the (encrypted) value;
# this adds the header NAME, which is not sensitive, so it's a plain
# column shown back on edit.
class AddSecretHeaderToAlertDestinations < ActiveRecord::Migration[8.1]
  def change
    add_column :alert_destinations, :secret_header, :string
  end
end
