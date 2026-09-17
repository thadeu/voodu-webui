# frozen_string_literal: true

# call_key — the identity of the WHOLE call, resolved at ingest by looking at
# neighbouring rows (HepCallKeys), as opposed to corr_id, which each row
# computes from itself alone.
#
# corr_id turned out to split real calls: the collector fills x_cid per
# MESSAGE from that message's X-CID header, and in production the INVITE
# FreeSWITCH sends carries the upstream SBC's X-CID while the 100/180/403/ACK
# of the very same dialog carry none — so one dialog became two "calls", and
# every gateway-failover INVITE (new Call-ID, same X-CID) became another. The
# Calls view counted ~100 for ~20 real calls.
#
# Seeded with corr_id so no row is NULL and every query stays indexable from
# the first boot; the transitive pass is `bin/rails hep3:backfill_call_keys`,
# run once after deploy (kept out of the migration so a release never waits
# on it). Rows written from now on are resolved by the poller.
class AddCallKeyToHepMessages < ActiveRecord::Migration[8.1]
  def up
    add_column :hep_messages, :call_key, :string

    execute <<~SQL
      UPDATE hep_messages
      SET call_key = COALESCE(NULLIF(json_extract(payload, '$.x_cid'), ''), json_extract(payload, '$.call_id'))
    SQL

    # Hot path — a call's full timeline (ladder) + the Calls view grouping.
    add_index :hep_messages, [:server_id, :scope, :name, :call_key, :ts_epoch],
      name: "idx_hep_messages_call_key"

    # The resolver's two lookups per batch: rows sharing a Call-ID, rows
    # sharing an X-CID — both scoped to the reader instance.
    add_index :hep_messages, [:server_id, :scope, :name, :call_id],
      name: "idx_hep_messages_instance_call_id"
    add_index :hep_messages, [:server_id, :scope, :name, :x_cid],
      name: "idx_hep_messages_instance_x_cid"
  end

  def down
    remove_index :hep_messages, name: "idx_hep_messages_instance_x_cid"
    remove_index :hep_messages, name: "idx_hep_messages_instance_call_id"
    remove_index :hep_messages, name: "idx_hep_messages_call_key"
    remove_column :hep_messages, :call_key
  end
end
