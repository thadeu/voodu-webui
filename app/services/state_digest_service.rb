# frozen_string_literal: true

# StateDigestService — persist + broadcast layer shared by:
#
#   - StateSyncIslandJob (Ruby fetches /pods + /system via
#     Voodu::Client, hands the parsed JSON to `.from_parsed`)
#   - PollerDigestJob (Go binary fetched + wrote two files to
#     `storage/poller/state/<sync_hash>/`; the job reads them and
#     hands to `.from_folder`)
#
# Both paths converge on `.persist`, which does the atomic snapshot
# replace + `state-tick` broadcast that pages everywhere react to.
#
# Folder shape (Go side contract):
#
#   storage/poller/state/<sync_hash>/
#     pods.json     — JSON array (the `data.pods` slice)
#     system.json   — JSON object (the `data` from /system)
#
# Atomicity model is inherited from PodSnapshot + SystemSnapshot:
# the outer transaction here wraps both replace_for_island! calls so
# either both snapshots commit or neither does. SQLite WAL guarantees
# readers see one consistent post-state, not the empty middle.
class StateDigestService
  # Filenames the Go binary writes. Constants so both the Go
  # contract test and this service share one source of truth — if
  # the wire shape changes, this list changes here.
  PODS_FILE   = "pods.json"
  SYSTEM_FILE = "system.json"

  def self.from_folder(folder_path:, tenant_id:)
    folder = Pathname.new(folder_path)

    # The Go binary writes the raw PAT envelope verbatim:
    #
    #   pods.json   → { "status": "ok", "data": { "pods": [...],
    #                                              "degraded": [...] } }
    #   system.json → { "status": "ok", "data": { "host": {...}, ... } }
    #
    # `PodSnapshot.replace_for_island!` + `SystemSnapshot.replace_for_island!`
    # expect the already-unwrapped shapes (Array of pod Hash, system Hash).
    # `StateSyncIslandJob` does that unwrap via `Voodu::Client#pods/#system`
    # (which strips `status` + returns `data`) and then `pods_payload_from`
    # (which pulls `data.pods` out). The digest path bypasses both layers,
    # so we replicate the same unwrap here so the two ingest paths feed
    # PodSnapshot the same shape.
    pods_envelope   = read_json(folder.join(PODS_FILE),   default: {})
    system_envelope = read_json(folder.join(SYSTEM_FILE), default: {})

    pods   = unwrap_pods(pods_envelope)
    system = unwrap_system(system_envelope)

    from_parsed(pods: pods, system: system, tenant_id: tenant_id)
  end

  # from_parsed — entry point for the Ruby-fetch path. Caller has
  # already parsed both responses out of the JSON envelope.
  #
  # `tenant_id` is the Island primary key (legacy domain table is
  # still `islands`, but the poller feature uses `tenant_id` as the
  # internal name end-to-end — matches the wire contract from the
  # Go binary and the column on `poller_digests`).
  def self.from_parsed(pods:, system:, tenant_id:)
    island = Island.find_by(id: tenant_id)
    return unless island

    persist(island, pods, system)
    broadcast_state_tick(island)
    island
  end

  # persist — the snapshot replace half. Public so the existing
  # StateSyncIslandJob can wrap it in its own outer transaction
  # alongside `island.update_columns(last_synced_at: ...)`.
  def self.persist(island, pods, system)
    ActiveRecord::Base.transaction do
      PodSnapshot.replace_for_island!(island, pods)
      SystemSnapshot.replace_for_island!(island, system)
    end
  end

  # broadcast_state_tick — same triple-broadcast (status pill +
  # status dot + state_tick action) that StateSyncIslandJob does.
  # Extracted here so the Go-fed path produces an identical UI
  # update to the Ruby-fed path.
  #
  # Rescued generically — a Solid Cable transport blip mid-process
  # shouldn't fail the digest; the next tick will refresh the UI.
  def self.broadcast_state_tick(island)
    pill_html = Components::UI::StatusPill.new(status: :online).call
    dot_html  = Components::UI::StatusDot.new(status: :online).call
    stream    = "island-state-#{island.id}"

    Turbo::StreamsChannel.broadcast_update_to(
      stream,
      target: "island-status-pill-#{island.id}",
      html:   pill_html
    )
    Turbo::StreamsChannel.broadcast_update_to(
      stream,
      target: "island-status-dot-#{island.id}",
      html:   dot_html
    )
    Turbo::StreamsChannel.broadcast_action_to(stream, action: :state_tick)
  rescue StandardError => e
    Rails.logger.warn(
      "state-digest broadcast island=#{island.key} failed: #{e.class}: #{e.message}"
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
