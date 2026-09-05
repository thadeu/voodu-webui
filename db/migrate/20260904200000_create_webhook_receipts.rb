# frozen_string_literal: true

# Webhook::Receipt — the comprovante that something arrived, and what we did
# with it.
#
# ONE ROW PER DELIVERY, whatever the outcome. Before this, only a delivery that
# QUEUED work left a trace: a refused signature, a repository no server listed,
# an event we ignore — all vanished. From inside the product, "GitHub never
# called", "we refused it" and "nothing matched" were the same silence, and
# that is what made a failing webhook undiagnosable without a console.
#
# ## Provider-agnostic on purpose
#
# GitHub today, Stripe next. `provider` + `event` + a JSON body is the shape
# every webhook has; anything provider-specific lives in `details` rather than
# in a column that is null for everyone else.
#
# ## The arrow points from the child
#
# There is no polymorphic `subject` here. A single delivery legitimately
# produces MANY things — one push to a repository listed on two servers creates
# two deployments — and one `belongs_to` cannot hold two. So the children carry
# `webhook_receipt_id` and "everything this delivery produced" is a query
# against them.
#
# ## Not partitioned, deliberately
#
# The row count is one per push: a busy customer writes thousands a month, not
# millions. Partitioning exists to make `DROP TABLE` instant where a `DELETE`
# would scan; at this volume the delete is imperceptible, and partitioning
# would cost this project its `schema.rb` (partitions cannot be expressed
# there) plus a Postgres-only path — while SQLite, the default here, has no
# declarative partitioning at all.
#
# Designed so that partitioning LATER is cheap: nothing holds a foreign key
# pointing AT a receipt (that is what blocks dropping a partition),
# `received_at` is always set, and retention is a job from day one.
class CreateWebhookReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_receipts do |t|
      t.string :provider, null: false
      t.string :event, null: false

      # The delivery id as the PROVIDER names it: X-GitHub-Delivery, Stripe's
      # event id. Unique per provider, which is what makes a retry a no-op —
      # and it now covers deliveries we REFUSED, which the old dedupe on
      # `deployments.delivery_id` could not.
      t.string :external_id

      t.string :status, null: false

      # What this delivery is ABOUT, in the provider's own terms: a repository
      # for GitHub, a customer for Stripe. One generic column rather than one
      # per provider, because the only thing asked of it is "filter by this".
      t.string :reference

      # Nullable: a delivery that failed its signature has no org we are
      # willing to name, and one that matched nothing has none to name.
      t.string :org_id

      # The body as it arrived, and whatever we want to note. `payload` is
      # evidence; `details` is our own reading of it.
      t.json :payload, default: {}, null: false
      t.json :details, default: {}, null: false

      t.datetime :received_at, null: false

      t.timestamps
    end

    # THE DEDUPE. A provider retries what it did not get a 2xx for, and retries
    # the same id — so a unique index turns "did we already see this" from a
    # question into an insert that fails.
    #
    # Partial, because a delivery may arrive without an id (a hand-made curl, a
    # provider that does not send one) and any number of those may coexist.
    add_index :webhook_receipts, [:provider, :external_id],
      unique: true, where: "external_id IS NOT NULL",
      name: "index_webhook_receipts_on_delivery"

    # The listing: newest first, optionally narrowed. `received_at` and not
    # `created_at` — they are the same today and will not be the day a
    # provider's timestamp is what we sort by.
    add_index :webhook_receipts, :received_at
    add_index :webhook_receipts, [:provider, :status, :received_at]
    add_index :webhook_receipts, [:reference, :received_at]
  end
end
