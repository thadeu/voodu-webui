# frozen_string_literal: true

# integrations — one row per org's connection to a source provider.
#
# ONE ROW PER ORG, not per repository, and that is what makes "connected and
# nothing configured yet" representable — which is exactly the state in the
# instant after the GitHub callback. A row per repository would need a row with
# a null repo to mean that, and a row that means something different from its
# siblings is a row somebody reads wrong.
#
# A COLUMN EXISTS TO BE INDEXED; everything else is jsonb. The same rule
# metric_samples follows in this codebase, for the same reason: `external_id`
# is looked up on every push, so it earns a column and an index. `account_login`
# and the repository list are read whole and queried by nobody, so they live in
# the blob and a new field there is not a migration.
#
# `external_id` and not `installation_id`: the column is provider-agnostic —
# GitLab calls this something else. The GitHub word is an alias on the model,
# where it reads better.
#
# WHAT THE CONFIG DELIBERATELY DOES NOT HOLD: branch, watch paths, scope, or
# which manifest to apply. Branch and allowed scopes live in the trigger on the
# customer's box; when a deploy fires and what it applies live in
# `.voodu/**/*.yml` in their repository. Storing either here would create a
# second copy that can disagree with the one that decides — and it would be the
# place somebody edits to redirect a deploy. See invariant II in the PRD.
#
# INVARIANT IV lives in the indexes: every lookup starts at org_id, so tenant
# scoping is a property of the query plan rather than a check a new code path
# can forget.
class CreateIntegrations < ActiveRecord::Migration[8.1]
  def change
    create_table :integrations do |t|
      t.string :org_id, null: false

      # The operator's own label. Two GitHub connections cannot coexist per
      # org today, but a name is what makes a list of providers readable
      # without decoding anything.
      t.string :name

      t.string :provider, null: false

      # The provider's id for this connection — GitHub's installation_id.
      # A NUMBER, and it opens nothing on its own: minting a token from it
      # needs the App's private key, which lives on this installation and
      # never travels.
      t.string :external_id, null: false

      # `active` | `revoked`. Revoked rather than deleted: an installation the
      # customer removed on GitHub's side is history worth keeping, and a row
      # that vanishes takes the answer to "why did deploys stop" with it.
      t.string :status, null: false, default: "active"

      # { account_login, repos: [{ repo, server_id, trigger_id }] }
      t.json :config, default: {}, null: false

      t.timestamps
    end

    # One row per (org, provider, external_id) — NOT per (org, provider).
    #
    # An org may connect SEVERAL GitHub accounts: `acme-corp` feeding one
    # server and `acme-labs` feeding another. Those are two installations with
    # two ids, and a constraint on (org, provider) would refuse the second for
    # no reason anybody could explain.
    #
    # What it still forbids is the same installation recorded twice for one
    # org, which is the actual duplicate.
    add_index :integrations, [:org_id, :provider, :external_id], unique: true

    # The webhook's only lookup. It arrives with no session, no org and no
    # user — just an installation id — and this is how it gets from there to
    # the rows without a scan.
    #
    # NOT unique: the same GitHub account can be connected by two orgs of the
    # same installation, and both must be found. A delivery resolves to a set
    # of (server, trigger) pairs, and each server carries its own org.
    add_index :integrations, [:provider, :external_id]
  end
end
