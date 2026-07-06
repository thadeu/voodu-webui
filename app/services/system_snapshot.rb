# frozen_string_literal: true

# SystemSnapshot — the service that takes the controller's
# `/system` response and upserts the single `systems` row for one
# server.
#
# Sibling of `PodSnapshot`; both are called from `StateSyncServerJob`
# every 10s, inside the same outer transaction so pods + system +
# `server.last_synced_at` commit together or roll back together.
#
# Unlike `PodSnapshot` (which manages a SET of rows per server and
# uses delete-and-bulk-insert), this service writes a single row
# via `upsert` — much cheaper than delete-then-insert for a 1:1
# relation. The unique index on `systems.server_id` makes the
# upsert deterministic.
#
# Input shape: `system_payload` is the `data` hash from
# `/system` (full controller response). The hash is round-tripped
# to JSON and stored verbatim so downstream readers don't lose any
# field (new /system fields appear automatically without a
# migration).
class SystemSnapshot
  # replace_for_server! — upsert the system snapshot for one server.
  # Returns nothing.
  #
  # `system_payload` accepts a Hash (typical: parsed JSON from the
  # controller). nil or non-Hash is a no-op — the sync job logs the
  # failure separately; we don't want to overwrite a previously
  # good snapshot with garbage.
  def self.replace_for_server!(server, system_payload)
    return unless system_payload.is_a?(Hash)

    now = Time.current

    System.upsert(
      {
        server_id: server.id,
        payload: system_payload.to_json,
        synced_at: now,
        created_at: now,
        updated_at: now
      },
      unique_by: :index_systems_on_server_id
    )
  end
end
