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
  # Read from the local snapshot the sync pipeline maintains.
  # Sub-millisecond, and it keeps answering while the controller is
  # down: the Settings "About" card goes on showing the last-known
  # hostname / kernel / CPU / memory / disk / uptime / voodu version
  # instead of dashing every field.
  def self.fetch(server)
    return nil if server.nil?

    server.system&.payload_hash
  end

  def self.invalidate(server)
    Rails.cache.delete(cache_key(server))
  end

  def self.cache_key(server)
    "voodu:system:v1:server:#{server.id}"
  end
end
