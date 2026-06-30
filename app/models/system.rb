# frozen_string_literal: true

# System — local snapshot of `/api/pat/v1/system` for one island.
# Exactly one row per island, kept in lockstep with the controller by
# `StateSyncIslandJob` (every 10s). Topbar uptime chip + Overview
# host CPU/Mem cards read from this row instead of making a fresh
# HTTP call per page render.
#
# Class name note: `System` is a generic top-level constant in Ruby
# (Kernel#system is a method, not a class — no collision). Sibling
# of the `Pod` model in shape and intent: read-only ActiveRecord
# noun, with the `SystemSnapshot` service as the single writer.
# Don't add validations or callbacks; the upsert path skips them.
#
# Schema (see db/migrate/<ts>_create_systems.rb):
#   id, island_id (unique), payload (JSON text), synced_at, timestamps
class System < ApplicationRecord
  belongs_to :island

  # payload_hash — lazy-parsed view of the `payload` JSON column.
  # Same memoisation idiom as Pod#payload_hash so callers can read
  # multiple hot fields off a single instance without paying the
  # JSON parse N times.
  def payload_hash
    @payload_hash ||= JSON.parse(payload || "{}")
  rescue JSON::ParserError
    @payload_hash = {}
  end

  # ── Hot-field accessors ────────────────────────────────────────
  #
  # The /system response shape (from internal/systemstats.Snapshot):
  #
  #   { host: { hostname, kernel, uptime_seconds, boot_time },
  #     cpu:  { percent, cores, load_1, load_5, load_15 },
  #     mem:  { used_bytes, total_bytes, available_bytes },
  #     disk: { used_bytes, total_bytes, filesystem },        # may be []
  #     io:   { read_bytes_per_sec, write_bytes_per_sec },
  #     net:  { rx_bytes_per_sec, tx_bytes_per_sec },
  #     voodu: { version } }
  #
  # Accessors below peel one level so callers read `system.hostname`
  # instead of `system.payload_hash["host"]["hostname"]`.

  # host_block — the full host nested hash. Use the named getters
  # below for hot fields; this is here for the "give me everything"
  # surfaces (Settings page debug).
  def host_block
    payload_hash["host"] || {}
  end

  # hostname — what the controller reports as the kernel hostname.
  # Distinct from `island.host` (which is the URL the WebUI uses to
  # REACH the controller).
  def hostname
    host_block["hostname"].to_s
  end

  # uptime_seconds — host uptime in seconds. Topbar humanises this
  # into "Nd Nh" via Island#uptime; keep the raw number here so
  # other surfaces (charts, alerts) can derive their own format.
  def uptime_seconds
    host_block["uptime_seconds"].to_i
  end

  # kernel — informational badge ("debian 6.1.0-48-arm64") shown on
  # the Settings page.
  def kernel
    host_block["kernel"].to_s
  end

  # boot_time — ISO timestamp of last boot. Convenience for the
  # Settings page's "Booted at" row.
  def boot_time
    host_block["boot_time"].to_s
  end

  # booted_at — boot_time parsed to a Time, or nil when absent/garbage.
  # Island#uptime derives live uptime as `now - booted_at` so the chip
  # ticks up BETWEEN syncs (instead of freezing on the snapshot's
  # uptime_seconds) and reads identically on every page.
  def booted_at
    raw = host_block["boot_time"]
    return nil if raw.blank?

    Time.iso8601(raw.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # cpu / mem / disk — top-level hashes mirroring /system's
  # structure. Each carries the relevant fields:
  #   cpu  → { percent, cores, load_1, load_5, load_15 }
  #   mem  → { used_bytes, total_bytes, available_bytes }
  #   disk → { used_bytes, total_bytes, filesystem }
  def cpu
    payload_hash["cpu"] || {}
  end

  def mem
    payload_hash["mem"] || {}
  end

  def disk
    payload_hash["disk"] || {}
  end

  # voodu_version — the controller binary version reported under
  # `voodu.version`. Used by the Settings page's "Agent" card.
  def voodu_version
    (payload_hash["voodu"] || {})["version"].to_s
  end

  # plugins — installed-plugin summaries carried in the /system sync,
  # each a Hash {"name", "version", "aliases"}. Empty when the
  # controller predates the field or nothing is installed. The Settings
  # page lists these; feature gates read them via plugin_installed?.
  def plugins
    payload_hash["plugins"] || []
  end

  # plugin_installed? — whether a plugin answering to `name` is
  # installed, matching the canonical name OR any alias (so "hep" finds
  # "hep3"). Reads the locally-synced row, so WebUI feature gates resolve
  # offline and free at render time — no live controller call.
  def plugin_installed?(name)
    wanted = name.to_s
    return false if wanted.empty?

    plugins.any? do |p|
      p["name"].to_s == wanted || Array(p["aliases"]).map(&:to_s).include?(wanted)
    end
  end
end
