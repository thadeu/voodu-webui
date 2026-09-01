# frozen_string_literal: true

# StateDigestService — persist + broadcast layer for the poller's state
# stream. The Go binary fetches /pods + /system, writes two files to
# `storage/poller/state/<sync_hash>/`, and PollerDigestJob hands the folder
# to `.from_folder`. `.persist` does the atomic snapshot replace and the
# `state-tick` broadcast that pages everywhere react to.
#
# There used to be a second writer — a Ruby job fetching the same two
# endpoints per tick — and this class was the seam where both converged.
# The job is gone; the unwrap-and-persist shape it left behind is still the
# contract the Go side writes against.
#
# Folder shape (Go side contract):
#
#   storage/poller/state/<sync_hash>/
#     pods.json     — JSON array (the `data.pods` slice)
#     system.json   — JSON object (the `data` from /system)
#
# Atomicity model is inherited from PodSnapshot + SystemSnapshot:
# the outer transaction here wraps both replace_for_server! calls so
# either both snapshots commit or neither does. SQLite WAL guarantees
# readers see one consistent post-state, not the empty middle.
class StateDigestService
  # Filenames the Go binary writes. Constants so both the Go
  # contract test and this service share one source of truth — if
  # the wire shape changes, this list changes here.
  PODS_FILE = "pods.json"
  SYSTEM_FILE = "system.json"

  def self.from_folder(folder_path:, server_id:)
    folder = Pathname.new(folder_path)

    # The Go binary writes the raw PAT envelope verbatim:
    #
    #   pods.json   → { "status": "ok", "data": { "pods": [...],
    #                                              "degraded": [...] } }
    #   system.json → { "status": "ok", "data": { "host": {...}, ... } }
    #
    # `PodSnapshot.replace_for_server!` + `SystemSnapshot.replace_for_server!`
    # expect the already-unwrapped shapes (Array of pod Hash, system Hash).
    # `Voodu::Client#pods/#system` do that unwrap for in-process callers
    # (strip `status`, return `data`, then pull `data.pods` out). The digest
    # path bypasses the client entirely, so the same unwrap is replicated
    # here: PodSnapshot gets one shape no matter who fetched.
    pods_envelope = read_json(folder.join(PODS_FILE), default: {})
    system_envelope = read_json(folder.join(SYSTEM_FILE), default: {})

    pods = unwrap_pods(pods_envelope)
    system = unwrap_system(system_envelope)

    from_parsed(pods: pods, system: system, server_id: server_id)
  end

  # from_parsed — the persist step once the two payloads are unwrapped. Caller has
  # already parsed both responses out of the JSON envelope.
  #
  # `server_id` is the Server primary key (legacy domain table is
  # still `servers`, but the poller feature uses `server_id` as the
  # internal name end-to-end — matches the wire contract from the
  # Go binary and the column on `poller_digests`).
  def self.from_parsed(pods:, system:, server_id:)
    server = Server.find_by(id: server_id)
    return unless server

    persist(server, pods, system)
    # last_synced_at is bumped HERE, and this is the only place that does it
    # now. It used to be skipped on this path (the Ruby job bumped its own),
    # which froze the column — and the "updated Ns ago" pill — while the
    # snapshots underneath stayed fresh.
    server.update_columns(last_synced_at: Time.current)
    # A successful digest means the poller just reached the controller —
    # confirm it online. This is the ONLY health-warm path: without it
    # status_for reads :unknown forever and the pill never turns green.
    ServerHealth.warm(server, online: true)
    broadcast_state_tick(server)
    server
  end

  # persist — the snapshot replace half, in one transaction so a reader
  # never sees new pods beside an old system row.
  def self.persist(server, pods, system)
    ActiveRecord::Base.transaction do
      PodSnapshot.replace_for_server!(server, pods)
      SystemSnapshot.replace_for_server!(server, system)
    end
  end

  # broadcast_state_tick — the triple broadcast (status pill + status dot +
  # state_tick action) every page subscribes to. One method so the wire
  # contract lives in one place.
  #
  # Rescued generically — a Solid Cable transport blip mid-process
  # shouldn't fail the digest; the next tick will refresh the UI.
  def self.broadcast_state_tick(server)
    pill_html = Components::UI::StatusPill.new(status: :online).call
    dot_html = Components::UI::StatusDot.new(status: :online).call
    stream = "server-state-#{server.id}"

    Turbo::StreamsChannel.broadcast_update_to(
      stream,
      target: "server-status-pill-#{server.id}",
      html: pill_html
    )
    Turbo::StreamsChannel.broadcast_update_to(
      stream,
      target: "server-status-dot-#{server.id}",
      html: dot_html
    )
    Turbo::StreamsChannel.broadcast_action_to(stream, action: :state_tick)
  rescue => e
    Rails.logger.warn(
      "state-digest broadcast server=#{server.key} failed: #{e.class}: #{e.message}"
    )
  end

  # read_json — safe JSON load with explicit default for missing /
  # malformed files. We tolerate missing files (e.g. the Go binary
  # only had /pods this tick, /system was 5xx) by falling back to
  # the empty default — PodSnapshot / SystemSnapshot accept Array.()
  # and nil-equivalent inputs without raising.
  def self.read_json(path, default:)
    return default unless File.exist?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError
    default
  end

  # unwrap_pods — peel the PAT envelope down to the pods array.
  #
  # Accepts three shapes, in order of likelihood:
  #
  #   1. Full envelope (Go binary path):
  #      `{ "status": "ok", "data": { "pods": [...], "degraded": [...] } }`
  #   2. Already-unwrapped `data` Hash (defensive — e.g. a future Go
  #      version that does the unwrap on its end):
  #      `{ "pods": [...], "degraded": [...] }`
  #   3. Bare array (legacy controllers that return the array directly):
  #      `[ {...}, {...} ]`
  def self.unwrap_pods(envelope)
    return envelope if envelope.is_a?(Array)
    return [] unless envelope.is_a?(Hash)

    inner = envelope["data"].is_a?(Hash) ? envelope["data"] : envelope
    Array(inner["pods"])
  end

  # unwrap_system — peel the PAT envelope down to the system Hash.
  # Same three-shape tolerance as `unwrap_pods`.
  def self.unwrap_system(envelope)
    return {} unless envelope.is_a?(Hash)

    inner = envelope["data"].is_a?(Hash) ? envelope["data"] : envelope
    inner.is_a?(Hash) ? inner : {}
  end

  private_class_method :read_json, :unwrap_pods, :unwrap_system
end
