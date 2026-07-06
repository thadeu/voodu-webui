# frozen_string_literal: true

# ServerState — read facade over the local snapshot tables.
#
# When `WAREHOUSE=1` is set, every page-render path (OverviewData,
# PodDetailData, ServerPods, ServerHealth) routes through here
# instead of making a fresh HTTP call to the controller. The
# `StateSyncServerJob` (every 10s) keeps the underlying tables
# fresh; pages get sub-millisecond reads off SQLite.
#
# When `WAREHOUSE=0` (default during rollout), `warehouse?` returns
# false and every caller falls back to its legacy HTTP-per-request
# path. The branch lives in each page service — this class never
# decides "should I use warehouse data?" on the caller's behalf.
#
# The page services consume the same shapes they did before — the
# pod hashes returned by `pods` mirror the controller's
# `/pods?detail=true&spec=true` payload exactly (they're stored
# verbatim in `pods.payload`); `system` returns the same hash
# shape as `/system`. Drop-in replacement at the read boundary.
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

  # warehouse? — single switch every page service consults to
  # decide between local-DB and HTTP-per-request. Reads fresh from
  # ENV each call so tests can flip the flag between examples
  # without restarting the process.
  def self.warehouse?
    ENV["WAREHOUSE"] == "1"
  end

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
  # freshest of the System snapshot's updated_at (bumped by BOTH ingest
  # paths — the Ruby StateSyncServerJob AND the Go-poller digest) and the
  # last_synced_at column (only the Ruby path maintains it). Reading the
  # column alone froze the "updated Ns ago" pill at the last Ruby sync
  # while the poller kept the snapshot fresh. nil for brand-new servers.
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

  # health_status — :online | :degraded | :offline derived purely
  # from sync recency. Replaces the active probe ServerHealth runs
  # under WAREHOUSE=0; same vocabulary so views don't have to
  # branch.
  def health_status
    age = synced_age_seconds
    return :offline if age.nil? || age > OFFLINE_THRESHOLD
    return :online if age <= ONLINE_THRESHOLD

    :degraded
  end
end
