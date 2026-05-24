# frozen_string_literal: true

# IslandPods — single source of truth for "give me the compact pod
# list of this island."
#
# Why a dedicated service vs. inline Rails.cache.fetch in each
# caller:
#
#   - BEFORE: LogsController + MetricsPageData each called
#     `client.pods(detail: false)` and wrapped it in their own
#     Rails.cache.fetch with a per-surface key
#     (voodu:logs_pods vs voodu:metrics_pods). Same payload,
#     different cells — opening /metrics after /logs paid the
#     round-trip again even though the data was already cached.
#
#   - AFTER: both call IslandPods.compact(client, island) → one
#     key (voodu:pods_compact:v1) → one warm reads, no duplicate
#     fetches. TTL + error handling live in one place.
#
# The "compact" qualifier is intentional — there's no equivalent
# for the detail=true payload because each surface that wants the
# joined stats has different freshness needs (Overview is OK with
# 10s, /pods page wants live, …). Add per-need wrappers if
# detail=true sharing ever becomes a problem.
class IslandPods
  TTL = 30.seconds

  # compact — `GET /api/pat/v1/pods` without `?detail=true`. Returns
  # an Array of hashes shaped like:
  #
  #   { "name" => "x.aaa", "scope" => "x", "resource_name" => "web",
  #     "replica_id" => "aaa", "kind" => "deployment",
  #     "image" => "nginx:latest", "status" => "running",
  #     "ports" => [80] }
  #
  # Empty array on any failure (no island, network error, malformed
  # payload). Callers should NOT raise — the surfaces that consume
  # this (picker dropdowns) gracefully hide themselves on [].
  def self.compact(client, island)
    return [] if client.nil? || island.nil?

    Rails.cache.fetch(cache_key(island), expires_in: TTL) do
      payload = client.pods(detail: false)
      Array(payload && payload["pods"])
    end
  rescue Voodu::Client::Error => e
    Rails.logger.warn("island_pods.compact: #{e.class} #{e.message}")
    []
  end

  # invalidate — drop the cached entry. Wire this from any action
  # that materially changes the pod set (apply / restart / delete)
  # if the operator's "I just deployed" → "the picker shows it" gap
  # ever feels long. For now the 30s TTL is short enough that we
  # don't bother.
  def self.invalidate(island)
    Rails.cache.delete(cache_key(island))
  end

  def self.cache_key(island)
    "voodu:pods_compact:v1:island:#{island.id}"
  end
end
