# frozen_string_literal: true

# StateSyncIslandJob — fetches the controller's runtime + host
# snapshot for ONE island and atomically replaces the local
# `pods` + `systems` rows. Runs every 10s (orchestrator tick) plus
# once immediately on island creation (`after_create_commit`).
#
# Wire shape (per sync tick):
#
#   1. GET /api/pat/v1/pods?detail=true&spec=true → pod list with
#      runtime + stats + declared spec from etcd, all in one request.
#   2. GET /api/pat/v1/system → host snapshot (CPU/mem/disk/uptime).
#   3. ActiveRecord::Base.transaction:
#        PodSnapshot.replace_for_island!(island, pods)
#        SystemSnapshot.replace_for_island!(island, system)
#        island.update_columns(last_synced_at: Time.current)
#
# Atomicity: the outer transaction ensures pods + system +
# last_synced_at update commit-or-rollback as a unit. A
# partial-failure mid-sync leaves the previous snapshot intact
# (pages keep rendering last-known data) and `last_synced_at`
# untouched (sidebar / IslandHealth show the staleness honestly).
#
# Offline behaviour: HTTP transport errors bubble up as
# Voodu::Client::Error. solid_queue retries per its default policy
# (5 attempts, exponential backoff) — buy time for transient
# blips. Auth errors discard immediately since they won't self-
# recover; the operator notices via the sidebar's stale badge.
#
# Sync interval (10s) is well above expected job runtime (~200ms)
# so overlapping jobs racing on the same island are not a concern
# in practice. If that changes, switch to solid_queue's
# `concurrency_key:` to serialise per island.
class StateSyncIslandJob < ApplicationJob
  queue_as :default

  # Bail without consuming retries on auth/scope errors — a PAT was
  # revoked or has insufficient scope; retrying every 10s won't fix
  # it. Operator sees stale snapshots and re-configures the PAT in
  # /islands/:id/edit.
  discard_on Voodu::Client::AuthError

  def perform(island_id)
    # POLLER_SPAWN=1 — the Go binary owns the per-island state
    # fetch; this job becomes a no-op so we don't double-hit
    # /api/pat/v1/pods + /system. Same flag as the log_tail jobs
    # and the metrics jobs — single switch, all three lanes.
    # Per-stream rollback (state-only off) lives on the binary
    # side via `POLLER_STATE=0`.
    return if ENV["POLLER_SPAWN"] == "1"

    island = Island.find_by(id: island_id)
    return unless island # deleted between orchestrator + job dispatch

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client = Voodu::Client.new(island)

    # Fetch both endpoints. Sequential rather than parallel —
    # combined typical latency is ~200-400ms, well under the 10s
    # interval, and serialising keeps the error surface and retry
    # semantics simple (one Faraday call at a time, one error at
    # a time). If runtime ever approaches the interval, switching
    # to Async / Concurrent::Future is a localised change.
    # stats: true (default) — fetch live CPU/Mem per pod. The /pods
    # table shows these as chips next to each pod row, and
    # /pods/:name renders them in the header card. The DX win is
    # significant (operator sees runtime numbers at a glance);
    # the cost (one batch docker stats call per sync tick) is no
    # longer a problem since the controller migrated docker stats
    # from `exec.Command` to the SDK with per-container stagger —
    # spikes that were near-100% now top out around 20%.
    pods_response = client.pods(detail: true, spec: true)
    system_response = client.system

    pods_payload = pods_payload_from(pods_response)
    system_payload = system_payload_from(system_response)

    # Outer transaction. StateDigestService.persist is itself
    # transactional (savepoint here under SQLite WAL), wrapping it
    # in this outer transaction keeps the freshness timestamp
    # update atomic with the snapshot replace — partial failure
    # mid-sync leaves both the previous snapshot AND the previous
    # last_synced_at intact so the staleness signal stays honest.
    ActiveRecord::Base.transaction do
      StateDigestService.persist(island, pods_payload, system_payload)

      # update_columns skips callbacks + validations + dirty
      # tracking — perfect for "just touch this timestamp" with
      # zero side-effects. updated_at is preserved as a separate
      # signal in case we ever care about "row touched" vs
      # "successfully synced".
      island.update_columns(last_synced_at: Time.current)
    end

    # Sync succeeded → controller is reachable + PAT valid + process
    # alive. Warm the IslandHealth cache so the sidebar / topbar
    # render :online without each page paying its own probe.
    # Under WAREHOUSE=1 this IS the only probe path — no other
    # surface calls /system or /health on the controller.
    IslandHealth.warm(island, online: true)

    # Push the fresh status to every open browser tab subscribed to
    # this island's state channel. Uses StateDigestService's
    # broadcast helper so the Go-fed digest path produces an
    # identical UI update — sidebar pill + status dot + state_tick
    # all in one place.
    StateDigestService.broadcast_state_tick(island)

    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    Rails.logger.info(
      "state-sync island=#{island.key} tenant=#{island.id} " \
      "pods=#{pods_payload.size} system=ok elapsed=#{elapsed_ms}ms"
    )
  rescue Voodu::Client::Error
    # Sync failed (controller offline, network blip, PAT scope
    # mismatch). Warm health → :offline so the badge flips
    # immediately on the next page render instead of waiting out
    # the IslandState.OFFLINE_THRESHOLD (120s). Then re-raise so
    # solid_queue's retry/discard policy kicks in for transport
    # errors (and discard_on Voodu::Client::AuthError covers the
    # auth/scope branch).
    if island
      IslandHealth.warm(island, online: false)
      broadcast_status_change(island, :offline)
    end

    raise
  end

  private

  # broadcast_status_change — pushes the new snapshot to any browser
  # tab subscribed to `island-state-#{id}`. Three signals per
  # broadcast (status pill + status dot + state_tick action).
  #
  # The :online path is now handled centrally by
  # `StateDigestService.broadcast_state_tick` (so the Go-fed digest
  # job emits an identical UI update). This local copy stays for
  # the :offline branch, where the job knows the controller is dead
  # and the digest service hasn't run.
  def broadcast_status_change(island, status)
    pill_html = Components::UI::StatusPill.new(status: status).call
    dot_html = Components::UI::StatusDot.new(status: status).call
    stream = "island-state-#{island.id}"

    # `update` (not `replace`) — `replace` swaps the entire target
    # element including its id, so the FIRST broadcast removes the
    # wrapper `<span id="island-status-pill-...">` and the second
    # broadcast finds nothing to target (silent no-op). The symptom
    # was: page body recovered correctly via state_tick, but the
    # topbar pill + sidebar dot stayed frozen on the previous status.
    # `update` rewrites innerHTML and keeps the id-bearing wrapper
    # in place across every flip.
    Turbo::StreamsChannel.broadcast_update_to(
      stream,
      target: "island-status-pill-#{island.id}",
      html: pill_html
    )

    Turbo::StreamsChannel.broadcast_update_to(
      stream,
      target: "island-status-dot-#{island.id}",
      html: dot_html
    )

    # state_tick fires last so the page-side handler runs AFTER the
    # status pill/dot replaces have applied. The frame.reload()
    # then refetches the operator's current page URL — which now
    # renders against the just-updated warehouse (stale banner
    # appears/disappears, pod statuses reflect online/offline).
    Turbo::StreamsChannel.broadcast_action_to(stream, action: :state_tick)
  rescue => e
    Rails.logger.warn(
      "state-sync broadcast island=#{island.key} failed: #{e.class}: #{e.message}"
    )
  end

  # pods_payload_from — Voodu::Client#pods returns the unwrapped
  # `data` hash (`{ "pods" => [...], "degraded" => [...] }` shape
  # from the controller). Peel `pods` and tolerate the legacy
  # array-shape just in case (some old controller versions used
  # to return the array directly).
  def pods_payload_from(response)
    case response
    when Array then response
    when Hash then Array(response["pods"])
    else []
    end
  end

  # system_payload_from — `data` hash for /system. Defensive
  # passthrough so a controller that ever returned a non-Hash
  # doesn't break the sync; SystemSnapshot guards non-Hash too.
  def system_payload_from(response)
    response.is_a?(Hash) ? response : nil
  end
end
