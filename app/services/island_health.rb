# frozen_string_literal: true

# IslandHealth — answers "is this controller reachable right now?"
# with a cached probe.
#
# Why a separate service, not on the model?
#   - Reachability is I/O-bound. Putting it directly on Island#status
#     would mean any page rendering N islands triggers N synchronous
#     HTTP calls on cold cache. Pulling it out makes the cost
#     explicit and lets callers batch/warm/skip on their own terms.
#   - Caching policy lives in one place. TTL changes don't sprawl.
#
# Reachability signal:
#   We probe /api/pat/v1/system because it's already there, fast on
#   the controller (gopsutil is microseconds), and PAT-authenticated
#   — so a successful response proves THREE things at once:
#     1. the PAT plane is listening on the configured port
#     2. the PAT is valid (auth middleware passed)
#     3. the controller process is alive (not just the listener)
#   "Is my PAT good and the box healthy?" is the question operators
#   actually want answered.
#
# Side-effect coupling with OverviewData:
#   OverviewData's fetch! already calls /system as part of its
#   normal data load. After fetch! it calls IslandHealth.warm to
#   write the cached status without spending another HTTP call.
#   Pages that render multiple islands (sidebar, /islands) then
#   read the warmed value for free.
class IslandHealth
  # 30s = sidebar updates within half a minute of a controller flap.
  # Long enough that flipping between dashboard tabs doesn't refire
  # probes, short enough that a real outage shows up before the
  # operator has had time to file a ticket about it.
  TTL = 30.seconds

  STATUSES = [:online, :offline, :unknown].freeze

  # status_for — READ-ONLY. Returns the cached status (:online |
  # :offline) or :unknown on a cold miss. NEVER probes synchronously:
  # rendering N islands is N cache reads, never N blocking HTTP calls.
  # A cold render shows :unknown for the few seconds until the next warm
  # tick, then the Turbo Stream broadcast flips the pill live.
  #
  # The cache is the single source of truth; WHO warms it:
  #
  #   WAREHOUSE=0 — `OverviewData.fetch_from_http!` warms after its
  #                 /system call (success → :online, failure → :offline).
  #
  #   WAREHOUSE=1 — `StateSyncIslandJob` warms every ~10s after its fetch
  #                 + broadcasts to `island-state-#{id}`. 3× per TTL → the
  #                 cache is always warm, status flips within ~10s of a
  #                 `systemctl stop`. This IS the only probe path.
  #
  # For a user-triggered "check the connection right now" (Settings
  # reconnect), call #refresh! — the only place that probes on demand.
  def self.status_for(island)
    Rails.cache.read(cache_key(island)) || :unknown
  end

  # refresh! — the intentional, synchronous probe: hit the controller
  # now, warm the cache with the result, and return it (:online |
  # :offline). For user-triggered reconnect flows, NEVER the render path.
  def self.refresh!(island, client: nil)
    online = probe(island, client)
    warm(island, online: online)

    online ? :online : :offline
  end

  # warm — write a known status into the cache without probing.
  # Called by OverviewData after its /system fetch succeeds or
  # raises, so the next render of the sidebar reflects the result
  # of that fetch instead of triggering its own probe.
  def self.warm(island, online:)
    Rails.cache.write(
      cache_key(island),
      online ? :online : :offline,
      expires_in: TTL
    )
  end

  # invalidate — drop the cached status. The next status_for read then
  # returns :unknown until a warm tick refills it (it no longer probes).
  # For an immediate re-probe, use #refresh! instead.
  def self.invalidate(island)
    Rails.cache.delete(cache_key(island))
  end

  def self.cache_key(island)
    "voodu:health:v1:island:#{island.id}"
  end

  # probe — the one HTTP call. Any error class counts as offline;
  # there's no useful distinction at the topbar between "401 PAT
  # rejected" and "ECONNREFUSED" — both mean the WebUI can't show
  # live data. Surface the specific error elsewhere (toast on
  # action, error banner on overview) when it matters.
  def self.probe(island, client)
    client ||= Voodu::Client.new(island)
    client.system
    true
  rescue
    false
  end

  private_class_method :probe

  # probe! — uncached, error-preserving preflight check used by
  # IslandsController#create. Returns nil on success; on failure
  # returns a SHORT human string ("Unauthorized — token rejected",
  # "Connection refused", "Timed out", …) suitable for the modal's
  # "Connection failed" banner.
  #
  # Why not just call `probe` + look up the cached :offline?
  #   - probe caches; the registration form needs an answer for THIS
  #     specific (endpoint, PAT) combination right now, not a stale
  #     read for some other island that happens to share the same id.
  #   - The form wants the REAL error class to render a useful
  #     message; probe collapses everything to a boolean.
  #
  # The island doesn't need to be persisted; we synthesize a
  # Voodu::Client directly.
  def self.probe!(island)
    Voodu::Client.new(island).system
    nil
  rescue Voodu::Client::Error => e
    humanize_error(e)
  rescue => e
    "#{e.class.name.demodulize}: #{e.message}"
  end

  # humanize_error — Voodu::Client::Error's :message carries the
  # transport detail (HTTP status, Faraday class, etc.). We rewrap
  # the common cases so the form banner reads like operator-speak
  # instead of stack-trace-speak.
  def self.humanize_error(err)
    msg = err.message.to_s
    case msg
    when /401|Unauthorized/i then "Agent rejected the token (401 Unauthorized). Double-check the PAT."
    when /403|Forbidden/i then "Agent rejected the token (403 Forbidden). The PAT lacks the required scope."
    when /ECONNREFUSED|connection refused/i then "Connection refused. Is the voodu agent running and the port reachable?"
    when /timeout|timed out/i then "Connection timed out. The host is reachable but the agent didn't answer in time."
    when /Failed to open TCP|no route/i then "Couldn't reach the host. Check the endpoint URL and firewall."
    else
      "Couldn't reach the agent: #{msg.truncate(160)}"
    end
  end
end
