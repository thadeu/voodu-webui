# frozen_string_literal: true

# ServerState — read facade over the local snapshot tables.
#
# Every page-render path (OverviewData, PodDetailData, ServerPods,
# ServerHealth) routes through here rather than calling the controller.
# The sync pipeline keeps the underlying tables fresh; pages get
# sub-millisecond reads off SQLite, and they keep rendering while the
# controller is unreachable — which is when an operator most needs the
# dashboard to open.
#
# There used to be a WAREHOUSE env flag selecting this against an
# HTTP-per-request path in each page service. It is gone: the HTTP path
# had no test of its own, two readers of the flag disagreed on what
# counted as "on" (`"1"` here, `"true"` or `"1"` in MetricsData, so
# WAREHOUSE=true split the app in half), and the only thing the flag
# reliably did was fail a test suite when somebody forgot to set it.
#
# The pod hashes returned by `pods` mirror the controller's
# `/pods?detail=true&spec=true` payload exactly — they are stored
# verbatim in `pods.payload`; `system` returns the same shape as
# `/system`.
#
# Staleness model:
#
#   :online   — last sync ≤ 30s ago (within 3× the 10s cadence)
#   :degraded — 30–120s   (1–3 missed ticks; UI shows amber)
#   :offline  — > 120s OR never synced (red badge, "stale" overlay)
#
# These thresholds line up with ServerHealth's existing TTL story
# so swapping from probe-based to recency-based health doesn't
# change what the operator sees in the sidebar / topbar dots.
class ServerState
  # Thresholds match ServerHealth's TTL (30s) so when we flip the
  # toggle the operator's notion of "this server feels live" is
  # preserved.
  ONLINE_THRESHOLD = 30.seconds
  OFFLINE_THRESHOLD = 120.seconds

  # for — convenience constructor so callers read
  # `ServerState.for(server)` rather than `ServerState.new(server)`.
  def self.for(server)
    new(server)
  end

  def initialize(server)
    @server = server
  end

  # pods — Array of pod hashes in the controller's
  # `/pods?detail=true&spec=true` shape (each hash carries
  # name/kind/scope/resource_name/replica_id/image/status/running/
  # stats/spec/env/networks/ports/state/…). Sorted by container_name
  # for stable ordering across reloads.
  #
  # Empty array when no sync has run yet for this server.
  def pods
    @pods ||= @server.pods.order(:container_name).map(&:payload_hash)
  end

  # system — Hash mirroring the controller's `/system` payload
  # (host/cpu/mem/disk/voodu/…). nil when no system snapshot row
  # exists yet for this server.
  def system
    @system ||= @server.system&.payload_hash
  end

  # synced_at — when the data on screen was actually last written. The
  # freshest of the System snapshot's updated_at and the last_synced_at
  # column; StateDigestService bumps both on every digest. Taking the max
  # dates from when two writers maintained them unevenly, and it costs
  # nothing to keep. nil for brand-new servers.
  def synced_at
    [@server.system&.updated_at, @server.last_synced_at].compact.max
  end

  # synced_age_seconds — seconds since the last sync, or nil when
  # the server has never synced. Convenience for "synced N s ago"
  # UI labels.
  def synced_age_seconds
    return nil if synced_at.nil?

    Time.current - synced_at
  end

  # stale? — true when the last sync is older than the ONLINE
  # threshold (or the server has never synced). Drives the
  # sidebar's amber/red badge.
  def stale?
    age = synced_age_seconds
    age.nil? || age > ONLINE_THRESHOLD
  end

  # health_status — :online | :degraded | :offline derived purely from
  # sync recency, which replaced the per-render probe. Same vocabulary,
  # so views never had to branch.
  def health_status
    age = synced_age_seconds
    return :offline if age.nil? || age > OFFLINE_THRESHOLD
    return :online if age <= ONLINE_THRESHOLD

    :degraded
  end
end
