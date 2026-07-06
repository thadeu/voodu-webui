# frozen_string_literal: true

# ServerSystem — single source of truth for "give me /system of
# this server."
#
# Same pattern as ServerPods (one cache cell, one TTL, one error
# bucket). OverviewData fetches /system as part of its bigger
# system+pods bundle; this service exposes a thinner read-path
# for surfaces like Settings that only need the system payload.
#
# Both surfaces share NOTHING by cache today (OverviewData has its
# own bundle key); if /system traffic ever spikes we can unify.
# v1 just keeps Settings cheap on cache hits.
class ServerSystem
  TTL = 30.seconds

  # fetch — returns the parsed /system payload (Hash) or nil on any
  # failure (no server, network error, malformed). Callers should
  # gracefully degrade — Settings shows "—" for the affected fields.
  #
  # WAREHOUSE=1 → read from the local snapshot maintained by
  # `StateSyncServerJob` (every 10s). Sub-millisecond + offline-
  # resilient: when the controller is down the Settings "About"
  # card keeps showing the last-known hostname / kernel / CPU /
  # memory / disk / uptime / voodu version — instead of dashing
  # every field. The sync job refreshes this on every tick so the
  # values track the agent live.
  def self.fetch(client, server)
    return nil if server.nil?

    return server.system&.payload_hash if ServerState.warehouse?

    return nil if client.nil?

    Rails.cache.fetch(cache_key(server), expires_in: TTL) do
      client.system
    end
  rescue Voodu::Client::Error => e
    Rails.logger.warn("server_system: #{e.class} #{e.message}")
    nil
  end

  def self.invalidate(server)
    Rails.cache.delete(cache_key(server))
  end

  def self.cache_key(server)
    "voodu:system:v1:server:#{server.id}"
  end
end
