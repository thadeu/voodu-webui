# frozen_string_literal: true

# IslandSystem — single source of truth for "give me /system of
# this island."
#
# Same pattern as IslandPods (one cache cell, one TTL, one error
# bucket). OverviewData fetches /system as part of its bigger
# system+pods bundle; this service exposes a thinner read-path
# for surfaces like Settings that only need the system payload.
#
# Both surfaces share NOTHING by cache today (OverviewData has its
# own bundle key); if /system traffic ever spikes we can unify.
# v1 just keeps Settings cheap on cache hits.
class IslandSystem
  TTL = 30.seconds

  # fetch — returns the parsed /system payload (Hash) or nil on any
  # failure (no island, network error, malformed). Callers should
  # gracefully degrade — Settings shows "—" for the affected fields.
  #
  # WAREHOUSE=1 → read from the local snapshot maintained by
  # `StateSyncIslandJob` (every 10s). Sub-millisecond + offline-
  # resilient: when the controller is down the Settings "About"
  # card keeps showing the last-known hostname / kernel / CPU /
  # memory / disk / uptime / voodu version — instead of dashing
  # every field. The sync job refreshes this on every tick so the
  # values track the agent live.
  def self.fetch(client, island)
    return nil if island.nil?

    return island.system&.payload_hash if IslandState.warehouse?

    return nil if client.nil?

    Rails.cache.fetch(cache_key(island), expires_in: TTL) do
      client.system
    end
  rescue Voodu::Client::Error => e
    Rails.logger.warn("island_system: #{e.class} #{e.message}")
    nil
  end

  def self.invalidate(island)
    Rails.cache.delete(cache_key(island))
  end

  def self.cache_key(island)
    "voodu:system:v1:island:#{island.id}"
  end
end
