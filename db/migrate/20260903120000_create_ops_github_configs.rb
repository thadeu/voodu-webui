# frozen_string_literal: true

# Ops::GithubConfig — the GitHub App this installation deploys through.
#
# Shaped like ops_sso_configs, and for the same reasons:
#
#   APPEND-ONLY. One row per change, newest wins. There is no update. For a
#   credential that can read every connected repository, "who changed this and
#   when" is worth more than a tidy single row — and it is the only record of
#   it we would ever have.
#
#   `provider` + JSON `settings`. GitHub is the only one today; GitLab and
#   Gitea spell their identifiers differently, and a schema built on GitHub's
#   words would need columns that are null for everyone else. Nothing queries
#   the settings — they are read whole and handed to whatever they configure.
#
# The two secrets get their own encrypted columns rather than living in the
# JSON blob: `encrypts` works per attribute, and a blob holding one secret
# among public fields is a blob somebody eventually logs.
class CreateOpsGithubConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :ops_github_configs do |t|
      t.string :provider, null: false

      # app_id, app_slug — public identifiers. The slug builds the install URL
      # (github.com/apps/<slug>/installations/new), which is the one thing an
      # operator has to be handed.
      t.json :settings, default: {}, null: false

      # The App's private key (.pem). It signs the JWT that mints per-repository
      # tokens, so it IS the product's access to every connected repository.
      t.text :private_key_ciphertext

      # Validates webhook HMAC. Separate from the key because they rotate
      # independently and because leaking either one alone should not require
      # rotating the other.
      t.text :webhook_secret_ciphertext

      t.string :configured_by_id

      t.timestamps
    end

    # Only ever read as "the newest one", the same access pattern the SSO table
    # has. No uniqueness on provider — a second row IS the update.
    add_index :ops_github_configs, :created_at
  end
end
