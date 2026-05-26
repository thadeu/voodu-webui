class CreatePods < ActiveRecord::Migration[8.1]
  def change
    # pods — local snapshot of every container the controller on `island`
    # reports via `/api/pat/v1/pods?detail=true&spec=true`. One row per
    # replica. Refreshed every 10s by `StateSyncIslandJob`; every page
    # render reads from this table instead of making a fresh HTTP call.
    #
    # When the controller goes offline, this table stays put — pages
    # continue rendering the last-known data with a "synced N min ago"
    # badge until the controller comes back and the sync resumes.
    create_table :pods do |t|
      # On-delete cascade so removing an Island purges its snapshots
      # in one transaction. The sync job is the only writer; clearing
      # the parent island's snapshots after delete is the only
      # remaining cleanup the sync job WOULD otherwise have to do.
      t.references :island, null: false, foreign_key: { on_delete: :cascade }

      # Hot fields extracted out of `payload` so the sidebar count
      # query (`island.pods.count`) and every "find this pod by name"
      # lookup go straight to an indexed column, no JSON parsing.
      t.string :container_name, null: false   # "voodu-x-web.a3f9"
      t.string :kind, null: false             # "deployment"
      t.string :scope, null: false            # "x"
      t.string :resource_name, null: false    # "web"
      t.string :replica_id                    # "a3f9" — null for non-replicated kinds

      # The entire /pods?detail=true row (runtime + stats + spec) as
      # a JSON blob — single source of truth for the rich pod-show
      # page. Same idiom as `MetricSample.payload`: keep the wire
      # shape verbatim so future fields land here for free without
      # a migration.
      t.text :payload, null: false

      # Timestamp of the controller fetch that produced this row.
      # Lets the UI show "synced 12s ago" per pod and lets the
      # IslandState facade compute staleness without re-parsing
      # the payload.
      t.datetime :synced_at, null: false

      t.timestamps
    end

    # Unique on (island, container_name) so the upsert in
    # `PodSnapshot.replace_for_island!` can use `insert_all` with a
    # natural conflict target. Container names are globally unique
    # within an island (docker enforces it).
    add_index :pods, [:island_id, :container_name], unique: true

    # Compound index that supports the most common filter from page
    # services: "give me pods of this kind in this scope for this
    # resource" (replica chips, scope picker, etc.).
    add_index :pods, [:island_id, :kind, :scope, :resource_name]
  end
end
