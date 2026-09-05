# frozen_string_literal: true

# Deployment — one push, on its way to one server.
#
# Written by the webhook the moment a delivery is accepted, BEFORE anything is
# attempted. That order is the whole design: the row is what makes a delivery
# idempotent, and a row created after the work would dedupe nothing.
#
# Shaped like `integrations` — few columns, one JSON blob:
#
#   The columns are the ones something QUERIES. delivery_id is unique because
#   that uniqueness IS the dedupe; org/server/repo are what a screen filters
#   by; status is what the queue picks up.
#
#   Everything else (the commit subject, the author, the manifests that were
#   applied, the resources that came out) lives in `details`. It is read whole,
#   by one screen, and giving each field a column would mean a migration every
#   time GitHub's payload or our executor grows a field.
class CreateDeployments < ActiveRecord::Migration[8.1]
  def change
    create_table :deployments do |t|
      # A string, because orgs carry UUID primary keys — `t.references` would
      # create an integer column that silently never matches.
      t.string :org_id, null: false
      t.references :server, null: false, foreign_key: true

      # Nullable on purpose: a deployment outlives the integration that started
      # it. Disconnecting GitHub must not take the history of what it deployed.
      t.references :integration, null: true, foreign_key: true

      t.string :repo, null: false
      t.string :ref
      t.string :sha

      # The trigger handle ON THE BOX. A string and not a reference — it lives
      # in etcd on the customer's server, not here.
      t.string :trigger_id

      # X-GitHub-Delivery. Null for a deploy started from the console, which
      # has no delivery to be the second copy of.
      t.string :delivery_id

      t.string :status, null: false, default: "queued"
      t.text :error

      t.json :details, default: {}, null: false

      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    # THE dedupe. GitHub retries a delivery it did not get a 2xx for, and it
    # retries the same id — so a unique index turns "did we already run this"
    # from a question into an insert that fails. Partial, because a console
    # deploy has no delivery id and any number of those may coexist.
    #
    # Scoped to the server, not global: one push legitimately fans out to
    # staging AND production, which is the same delivery landing twice on
    # purpose. Only the same delivery on the SAME server is a repeat.
    add_index :deployments, [:server_id, :delivery_id],
      unique: true, where: "delivery_id IS NOT NULL", name: "index_deployments_on_delivery"

    # The deployment list: one server, newest first.
    add_index :deployments, [:server_id, :created_at]

    add_index :deployments, [:org_id, :created_at]
    add_foreign_key :deployments, :orgs
  end
end
