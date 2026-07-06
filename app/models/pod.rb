# frozen_string_literal: true

# Pod — local snapshot of one container the voodu controller manages.
# One row per replica per server, kept in lockstep with the controller
# by `StateSyncServerJob` (every 10s). Pages render entirely from this
# table — no synchronous HTTP to the controller on the page render
# path. When the controller is offline the table stays put with the
# last-known state, so pages keep rendering useful data instead of
# blank-error.
#
# This model is READ-ONLY from the application's perspective. The
# `PodSnapshot` service (see `app/services/pod_snapshot.rb`) is the
# single writer, replacing the per-server row set atomically inside a
# transaction. Don't add `before_save`, validation callbacks, or
# `update!` helpers here — the upsert path bypasses them on purpose
# (10s syncs × N pods × callbacks would be wasteful), and adding
# them tempts ad-hoc mutations that drift from the sync source of
# truth.
#
# Schema (see db/migrate/<ts>_create_pods.rb):
#   id, server_id, container_name (unique with server_id),
#   kind, scope, resource_name, replica_id, payload (JSON text),
#   synced_at, timestamps
#
# `payload` mirrors the controller's `/pods?detail=true&spec=true` row
# verbatim (state + stats + spec + env + ports + …). The accessors
# below pull the hot fields out on demand and memoise the parsed
# hash per instance — the JSON parse happens once even when the
# same Pod row drives multiple UI surfaces.
class Pod < ApplicationRecord
  belongs_to :server

  # payload_hash — lazy-parsed view of the `payload` JSON column.
  # Memoised per instance so the chart_card, header, and any other
  # render call share a single parse. Returns {} on garbage input
  # (defensive: the sync job validates JSON before insert, but
  # a corrupted manual write shouldn't take the page down).
  def payload_hash
    @payload_hash ||= JSON.parse(payload || "{}")
  rescue JSON::ParserError
    @payload_hash = {}
  end

  # ── Hot-field accessors (read from payload_hash) ───────────────

  # stats — the live CPU/Mem/Net/Block snapshot the controller joined
  # in via /pods?detail=true. Nil when the controller's StatsCollector
  # hadn't populated yet at fetch time, or when this pod wasn't in
  # the daemon's stats batch.
  def stats
    payload_hash["stats"]
  end

  # spec — the declared manifest (kind, scope, name, spec body,
  # metadata) from etcd, joined in via ?spec=true. Nil for orphan
  # containers whose manifest was deleted while the container
  # outlived the prune.
  def spec
    payload_hash["spec"]
  end

  # state — the docker container state hash (Running, ExitCode,
  # StartedAt, FinishedAt, etc.). Used by the pod-show page's
  # "running for 2d 4h" header.
  def state
    payload_hash["state"]
  end

  # image — current image tag; mirrored from the top-level field of
  # the payload (also exposed as `image` from the docker inspect).
  def image
    payload_hash["image"].to_s
  end

  # status — docker `ps` status string ("Up 2 hours", "Exited (0) 5m
  # ago"). Convenient for the pods table.
  def status
    payload_hash["status"].to_s
  end

  # running — boolean shortcut. Sourced from the controller's
  # explicit `running` field rather than parsing `status` string.
  def running?
    payload_hash["running"] == true
  end

  # Env / networks / mounts / ports — the rich-inspect fields the
  # pod-show page renders. Each returns nil-ish defaults so views
  # can iterate without `&.` chains everywhere.
  def env
    payload_hash["env"] || {}
  end

  def networks
    payload_hash["networks"] || {}
  end

  def mounts
    payload_hash["mounts"] || []
  end

  def ports
    payload_hash["ports"] || []
  end

  # docker_id — the short docker container id, useful for the
  # "docker logs <id>" escape hatch the pod-show page surfaces.
  def docker_id
    payload_hash["id"].to_s
  end

  # created_at_iso — when docker created the container (NOT this
  # Pod row's Rails created_at). Iso string from the controller.
  def created_at_iso
    payload_hash["created_at"].to_s
  end
end
