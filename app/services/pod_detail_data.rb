# frozen_string_literal: true

# PodDetailData — `/pods/:name` data assembler. Same cache contract
# as OverviewData (10s TTL per [island, pod_name]; ?refresh=1
# bypasses). The raw pod hash from the PAT plane is exposed verbatim
# via `raw` so Spec/Network/Env/Labels cards can render bypass — no
# field renaming, no curated subsets, no surprises.
#
# Real values (from the joined `stats` block at /pods/:name):
#   - CPU%, memory used, memory limit (declared)
#
# Decorations (the API doesn't ship them yet):
#   - sparkline time series — synthesised from the current value;
#     server has no history to consume.
#
# Cards dropped vs older mockups (NET RX / NET TX) — the controller's
# UsageStats doesn't surface per-container network throughput; the
# previous code synthesised them from cpu_pct which gave operators
# fake numbers that LOOKED live. Better to omit a card than show
# fabricated data. Reintroduce when stats.go grows network fields.
class PodDetailData
  CACHE_TTL = 10.seconds

  attr_reader :error, :updated_at, :raw, :name

  def initialize(client, island, name, force_refresh: false)
    @client = client
    @island = island
    @name   = name
    @force  = force_refresh

    @raw        = nil
    @error      = nil
    @updated_at = Time.current
    @metrics    = MetricsData.new(client, island)

    fetch!
  end

  # Identity helpers — always return a string (never nil), pulling
  # from the raw payload when present and falling back to the URL
  # name decomposition otherwise.
  #
  # The PAT plane's /pods/:name detail JSON sometimes returns a leaner
  # shape than /pods (list) — no top-level "scope"/"resource_name"/
  # "replica_id" echoed back. Header rendering must not blow up on
  # that; this layer absorbs the difference so views/components stay
  # nil-safe.
  def scope         = pick("scope")         || split_name[:scope]
  def resource_name = pick("resource_name") || split_name[:resource]
  def replica_id    = pick("replica_id")    || split_name[:replica]
  def kind          = pick("kind")
  def image         = pick("image")
  def restarts      = (@raw&.dig("restarts") || 0).to_i
  def status_sym
    return :running if @raw&.dig("running")
    return :restarting if @raw&.dig("status").to_s.match?(/restart/i)
    return :stopped if @raw&.dig("status") == "stopped"

    :stopped
  end

  # Stat-card payloads (same shape Components::Overview::StatCard
  # consumes). Four cards in W7+: CPU / MEMORY / NET I/O / BLOCK I/O
  # — all real from the joined `stats` block on /pods/:name.
  #
  # NET I/O + BLOCK I/O show CUMULATIVE bytes since container start
  # (matching `docker stats` columns). The headline is the total
  # combined (rx+tx, read+write); the sub-line splits direction so
  # operators see both sides without two cards per metric.
  #
  # When the controller is older than W7 (no NET/BLOCK fields on
  # the payload), the values render as "0 B" with sub "no data"
  # — same graceful degradation pattern as the limit-less memory.
  def stat_cards
    [
      stat_card("CPU",       :CpuChipOutline,     "%.1f" % cpu_pct, "%",     cpu_sub, "var(--voodu-accent)", series_for_metric("cpu_percent")),
      stat_card("MEMORY",    :CircleStackOutline, mem_used_label,   mem_unit, mem_sub, "var(--voodu-blue)",  series_for_metric("mem_usage_bytes")),
      stat_card("NET I/O",   :SignalOutline,      net_total_label,  "",      net_sub, "var(--voodu-amber)",  series_for_metric("net_rx_delta_bytes")),
      stat_card("BLOCK I/O", :ServerStackOutline, blk_total_label,  "",      blk_sub, "var(--voodu-green)",  series_for_metric("block_read_delta_bytes"))
    ]
  end

  # series_for_metric — pulls real time-series via MetricsData
  # scoped to this pod's (scope, name). Aggregation on (scope, name)
  # means the chart survives container restarts (replica_id is
  # regenerated per spawn; (scope, name) is the stable identity).
  #
  # Returns [] when /metrics has no data yet (cold boot, controller
  # offline, never sampled). StatCard's `return if @series.blank?`
  # guard hides the sparkline cleanly — honest empty space is
  # better than a fake fluctuating line.
  def series_for_metric(metric)
    @metrics.points_for(
      source: :pod,
      metric: metric,
      range:  "1h",
      scope:  scope,
      name:   resource_name,
      # `pod:` pins the series to this specific replica (container).
      # Without it, the chart would aggregate across siblings —
      # confusing on the pod show page which is explicitly about
      # one replica's runtime.
      pod:    @name
    )
  end

  # The full age string for the header chip.
  def age_label
    return "—" unless @raw

    format_age(@raw["created_at"])
  end

  private

  # pick — String-or-Symbol key lookup that returns nil for blank
  # values (not the literal "" the API sometimes ships back).
  def pick(key)
    return nil if @raw.nil?

    val = @raw[key] || @raw[key.to_sym]
    val.to_s.presence
  end

  # split_name — best-effort decomposition of a container name like
  # "clowk-vd-docs.35a3" → { scope: "clowk-vd", resource: "docs",
  # replica: "35a3" }. Used as a fallback when the detail JSON
  # doesn't echo scope/resource_name/replica_id back.
  #
  # Splits on the LAST `.` for replica_id, then on the FIRST `-` for
  # scope vs resource. Handles "scope-name.rep" and degrades gracefully
  # on names that don't follow the convention (no `-` or no `.`).
  def split_name
    @split_name ||= begin
      n = @name.to_s
      if n.include?(".")
        base, _, rep = n.rpartition(".")
      else
        base, rep = n, nil
      end

      if base.include?("-")
        scope, _, res = base.partition("-")
      else
        scope, res = nil, base
      end

      { scope: scope.presence, resource: res.presence || n, replica: rep.presence }
    end
  end

  def fetch!
    return if @client.nil?

    Rails.cache.delete(cache_key) if @force

    cached = Rails.cache.read(cache_key)
    if cached
      @raw        = cached[:raw]
      @updated_at = cached[:fetched_at]
      return
    end

    @raw        = @client.pod(@name)
    @updated_at = Time.current

    Rails.cache.write(
      cache_key,
      { raw: @raw, fetched_at: @updated_at },
      expires_in: CACHE_TTL
    )
  rescue Voodu::Client::Error => e
    @error = e
  end

  def cache_key
    "voodu:pod_detail:v1:island:#{@island.id}:pod:#{@name}"
  end

  # stat_card — series is now an Array of real Float values from
  # MetricsData (caller passes via the last positional arg).
  # Renamed positional from `base_for_series` to `series` since we
  # no longer synthesise anything — what comes in IS the chart data.
  def stat_card(label, icon, value, unit, sub, color, series)
    {
      label:, icon:, value:, unit:, sub:, color:,
      period: "5m", delta: nil,
      series: series
    }
  end

  # ── Stat readers (real, from the joined `stats` block) ─────────
  #
  # The controller's /pods/{name} response now carries `stats.usage.*`
  # (live cgroup sample) and `stats.limits.*` (manifest-declared
  # limits). When stats is absent — controller older than W6, pod
  # stopped, race with delete, orphan filtered by collector — the
  # readers return 0/nil and the cards render "—" instead of
  # fabricated numbers.

  def cpu_pct
    @raw&.dig("stats", "usage", "cpu_percent").to_f.round(1)
  end

  def cpu_sub
    return "pod stopped" if status_sym != :running

    declared = @raw&.dig("stats", "limits", "cpu")
    declared.present? ? "limit #{declared}" : "no limit declared"
  end

  # mem_used_mb / mem_limit_mb — derived from `stats.usage.memory_*`
  # in bytes. 1024-based MB to match `free -m` / `docker stats`.
  # Returns 0 when the field is absent so the formatter can decide
  # what to render (label / "—").
  def mem_used_mb
    bytes = @raw&.dig("stats", "usage", "memory_usage_bytes").to_i
    return 0 if bytes.zero?

    (bytes.to_f / (1024 * 1024)).round
  end

  # mem_limit_mb prefers the manifest-declared limit (limits.memory_bytes)
  # over the runtime cgroup limit (usage.memory_limit_bytes). Reason:
  # when no manifest limit is declared, docker's cgroup limit equals
  # the host's total memory (gopsutil/cgroup semantics), which is
  # meaningless at the per-pod level. Manifest limit is what the
  # operator actually configured — the right denominator to compare
  # usage against. Nil when neither is set.
  def mem_limit_mb
    bytes = @raw&.dig("stats", "limits", "memory_bytes").to_i
    return nil if bytes.zero?

    (bytes.to_f / (1024 * 1024)).round
  end

  def mem_used_label
    return "—" if mem_used_mb.zero? && status_sym != :running

    mem_used_mb.to_s
  end

  def mem_unit
    mem_limit_mb.nil? ? "MB" : "/ #{mem_limit_mb} MB"
  end

  def mem_sub
    return "pod stopped"        if status_sym != :running
    return "no limit declared"  if mem_limit_mb.nil?
    return "—"                  if mem_limit_mb.zero?

    pct = (mem_used_mb.to_f / mem_limit_mb * 100).round
    "#{pct}% of limit"
  end

  # ── NET I/O ─────────────────────────────────────────────────────
  #
  # Cumulative since container start, from /pods/:name's joined
  # stats block. Headline is rx+tx total; sub-line splits direction
  # with arrows (↓ rx, ↑ tx) matching `docker stats` rendering.

  def net_rx_bytes
    @raw&.dig("stats", "usage", "net_rx_bytes").to_i
  end

  def net_tx_bytes
    @raw&.dig("stats", "usage", "net_tx_bytes").to_i
  end

  def net_total_label
    bytes = net_rx_bytes + net_tx_bytes
    bytes.zero? && status_sym != :running ? "—" : format_bytes(bytes)
  end

  def net_sub
    return "pod stopped" if status_sym != :running
    return "no data"     if net_rx_bytes.zero? && net_tx_bytes.zero?

    "↓ #{format_bytes(net_rx_bytes)}  ↑ #{format_bytes(net_tx_bytes)}"
  end

  def net_total_pct
    # Sparkline series amplitude. Capped at 100 because the synth
    # generator clamps to that range; this just scales the chart.
    # Log scale so a card with 4 GB and one with 4 MB don't both
    # look like flat ceilings — small movements still visible.
    bytes = net_rx_bytes + net_tx_bytes
    return 0 if bytes.zero?

    [Math.log10(bytes.to_f), 9.0].min * 10
  end

  # ── BLOCK I/O ──────────────────────────────────────────────────
  #
  # Same pattern as NET I/O — read+write cumulative bytes since
  # container start. ↓ read, ↑ write in the sub-line matches
  # operator's eye (read = bytes coming IN to the process from
  # disk; write = bytes going OUT to disk).

  def blk_read_bytes
    @raw&.dig("stats", "usage", "block_read_bytes").to_i
  end

  def blk_write_bytes
    @raw&.dig("stats", "usage", "block_write_bytes").to_i
  end

  def blk_total_label
    bytes = blk_read_bytes + blk_write_bytes
    bytes.zero? && status_sym != :running ? "—" : format_bytes(bytes)
  end

  def blk_sub
    return "pod stopped" if status_sym != :running
    return "no data"     if blk_read_bytes.zero? && blk_write_bytes.zero?

    "↓ #{format_bytes(blk_read_bytes)}  ↑ #{format_bytes(blk_write_bytes)}"
  end

  def blk_total_pct
    bytes = blk_read_bytes + blk_write_bytes
    return 0 if bytes.zero?

    [Math.log10(bytes.to_f), 9.0].min * 10
  end

  # format_bytes — same units `docker stats` uses (decimal kB/MB/GB
  # for I/O, even though memory uses binary MiB/GiB). Matches what
  # an operator running `docker stats` sees alongside the WebUI.
  def format_bytes(b)
    b = b.to_i
    return "0 B"                  if b.zero?
    return "#{b} B"               if b < 1000
    return "#{(b / 1000.0).round(1)} kB"     if b < 1_000_000
    return "#{(b / 1_000_000.0).round(1)} MB" if b < 1_000_000_000
    return "#{(b / 1_000_000_000.0).round(1)} GB" if b < 1_000_000_000_000

    "#{(b / 1_000_000_000_000.0).round(1)} TB"
  end

  # synth_series — deleted in M2.C4. Real time-series via
  # MetricsData replaced this; when /metrics returns empty (cold
  # boot, controller offline, no data yet) the StatCard's own
  # `return if @series.blank?` guard hides the sparkline cleanly.

  def format_age(iso)
    return "—" if iso.blank?

    t = Time.zone.parse(iso.to_s)
    distance = Time.current - t
    case distance
    when 0..59            then "#{distance.to_i}s"
    when 60..3599         then "#{(distance / 60).to_i}m"
    when 3600..86_399     then "#{(distance / 3600).to_i}h"
    when 86_400..2_591_999 then "#{(distance / 86_400).to_i}d #{((distance % 86_400) / 3600).to_i}h"
    else                       "#{(distance / 86_400).to_i}d"
    end
  rescue ArgumentError, TypeError
    "—"
  end
end
