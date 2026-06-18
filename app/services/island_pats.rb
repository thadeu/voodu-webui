# frozen_string_literal: true

# IslandPats — single source of truth for "give me the PAT list of
# this server".
#
# Distinct from IslandPods / IslandSystem because the failure mode
# matters here: a 403 (auth scope insufficient) is a NORMAL state for
# operators with a read-only PAT, not an error to swallow. Settings
# renders an explanatory hint instead of just an empty list.
#
# Returns a Result struct with three states:
#
#   - { ok: true,  pats: [...]  }   → list rendered
#   - { ok: false, forbidden: true } → "admin PAT required" hint
#   - { ok: false, error: <msg>  }  → transient failure (controller
#                                     down, timeout) — same hint but
#                                     phrased as a transport error
#
# Cached 30s on success. Auth-denied + transient errors are NOT
# cached so the next page render retries.
class IslandPats
  TTL = 30.seconds

  Result = Struct.new(:ok, :pats, :forbidden, :error, keyword_init: true) do
    def ok? = ok
    def forbidden? = !ok && forbidden
    def error? = !ok && !forbidden
  end

  def self.fetch(client, island)
    return Result.new(ok: false, error: "no island") if client.nil? || island.nil?

    cached = Rails.cache.read(cache_key(island))
    return Result.new(ok: true, pats: cached) if cached.is_a?(Array)

    pats = client.pats
    Rails.cache.write(cache_key(island), pats, expires_in: TTL)
    Result.new(ok: true, pats: pats)
  rescue Voodu::Client::AuthError => e
    Rails.logger.info("island_pats: PAT lacks admin scope: #{e.message}")
    Result.new(ok: false, forbidden: true)
  rescue Voodu::Client::TransportError => e
    # Controller offline / timeout — the common case. Never surface the
    # raw "Net::ReadTimeout with #<TCPSocket:(closed)>"; the operator
    # gets a friendly line, the detail goes to the log.
    Rails.logger.warn("island_pats: transport #{e.message}")
    Result.new(ok: false, error: "Controller unreachable — tokens will load once it's back online.")
  rescue Voodu::Client::Error => e
    Rails.logger.warn("island_pats: #{e.class} #{e.message}")
    Result.new(ok: false, error: "The controller returned an error loading tokens.")
  end

  def self.invalidate(island)
    Rails.cache.delete(cache_key(island))
  end

  def self.cache_key(island)
    "voodu:pats:v1:island:#{island.id}"
  end
end
