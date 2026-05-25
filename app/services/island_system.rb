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
  def self.fetch(client, island)
    return nil if client.nil? || island.nil?

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
