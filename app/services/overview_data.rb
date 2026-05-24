# frozen_string_literal: true

# OverviewData prepares the shape the Overview view consumes — a
# single decoded bundle the view can render without per-section
# decision logic.
#
# Real data (from the PAT plane):
#   - host CPU %, memory used/total      — from /stats
#   - pod list (name, image, running)    — from /pods
#
# Mocked (until the PAT plane exposes the field):
#   - sparkline time series  — synthesised from current value
#   - disk I/O, network throughput — synthetic
#   - host load averages, CPU cores, uptime — synthetic
#   - per-pod CPU%, memory used/total, restarts, ports — synthetic
#
# When the controller raises (network failure, auth, etc.) the
# `error` attribute carries it. The view uses that to decide between
# empty / error / happy renderings.
class OverviewData
  attr_reader :error, :updated_at, :cache_hit

  # Cache TTL for one island's overview snapshot. Short enough that
  # the operator's view is "live-ish" (≤ this many seconds stale), long
  # enough that browsing — opening the dashboard, flipping pod-status
  # filters, glancing at the table — doesn't fan out into N HTTP calls
  # to the PAT plane.
  #
  # Filters (?status=running, etc.) are pure Ruby operations on the
  # cached snapshot — they NEVER hit the network. Only a page load
  # past TTL, or an explicit "Refresh all" (`?refresh=1`), bypasses
  # the cache.
  CACHE_TTL = 10.seconds

  def initialize(client, island, force_refresh: false)
    @client     = client
    @island     = island
    @force      = force_refresh
    @stats      = nil
    @pods_raw   = []
    @updated_at = Time.current
    @error      = nil
    @cache_hit  = false
    fetch!
  end

  # Summary line under the H1 — "prod-edge-01 · 11 of 14 pods running
  # · load avg 3.41 / 2.86 / 2.41".
  def summary_line
    parts = [@island.name]
    parts << "#{pods_running_count} of #{pods_total} pods running"
    parts << "load avg #{load_1} / #{load_5} / #{load_15}"
    parts.join(" · ")
  end

  # The four StatCard payloads — passed straight as kwargs to
  # Components::Overview::StatCard.new(...).
  def stat_cards
    [
      stat_cpu, stat_memory, stat_disk, stat_network
    ]
  end

  # Pods normalised for the table component. Every pod is a hash with
  # the keys the PodsTable expects.
  def pods(filter_status: nil)
    list = @pods_raw.map { |p| prepare_pod(p) }
    return list if filter_status.nil?

    list.select { |p| p[:status] == filter_status }
  end

  def pods_total
    @pods_raw.size
  end

  def pods_running_count
    @pods_raw.count { |p| p["running"] }
  end

  # scopes — sorted unique list of scope names across all pods.
  # Surfaced in the Pods page subline ("5 scopes: clowk-vd, data, …").
  def scopes
    @pods_raw.map { |p| p["scope"] }.compact.uniq.sort
  end

  # Host facts surfaced in the subtitle / topbar. Mocked where the
  # PAT plane doesn't yet supply them.
  def cores
    8
  end

  def load_1  = 3.41
  def load_5  = 2.86
  def load_15 = 2.41

  private

  # fetch! — pulls the (stats + pods) snapshot via Rails.cache.fetch.
  #
  #   - Cache HIT  → no network. Snapshot is reused; @cache_hit = true.
  #                  @updated_at carries the original fetch time so the
  #                  topbar's "updated Ns ago" pill reflects data
  #                  freshness, not page render time.
  #   - Cache MISS → one /stats + one /pods call to the PAT plane.
  #                  Both responses cached under a per-island key.
  #   - force_refresh → cache invalidated up front (the "Refresh all"
  #                  button passes `?refresh=1`).
  #   - Voodu::Client::Error → stored on @error and NOT cached. The
  #                  next request retries immediately rather than
  #                  serving a stale failure for TTL seconds.
  def fetch!
    return if @client.nil?

    Rails.cache.delete(cache_key) if @force

    cached = Rails.cache.read(cache_key)
    if cached
      @cache_hit  = true
      @stats      = cached[:stats]
      @pods_raw   = cached[:pods]
      @updated_at = cached[:fetched_at]
      return
    end

    @stats = @client.stats
    # detail=true asks the controller for the enriched list (ports,
    # env, networks, restart_policy …). Same payload `vd describe pod`
    # consumes. The CLI/WebUI parity work guarantees the response is
    # byte-identical across the two planes.
    @pods_raw   = @client.pods(detail: true)["pods"] || []
    @updated_at = Time.current

    Rails.cache.write(
      cache_key,
      { stats: @stats, pods: @pods_raw, fetched_at: @updated_at },
      expires_in: CACHE_TTL
    )
  rescue Voodu::Client::Error => e
    # Don't poison the cache with a failure — let the next request
    # retry. Operators iterating on a misconfigured PAT shouldn't have
    # to wait TTL seconds to see their fix take effect.
    @error = e
  end

  # cache_key — namespaced per-island so two islands don't clobber
  # each other's snapshot. Bumped (`:v1`) so a schema change in the
  # cached hash (e.g. adding a `:degraded` key) won't read garbage from
  # old entries — change the suffix and old keys auto-expire on TTL.
  def cache_key
    "voodu:overview:v1:island:#{@island.id}"
  end

  # ── Stat cards ──────────────────────────────────────────────────

  def stat_cpu
    pct = host_cpu_pct
    {
      label: "CPU", icon: :CpuChipOutline,
      value: format("%.1f", pct), unit: "%",
      sub: "#{cores} cores · load #{load_1}",
      color: "var(--voodu-accent)",
      series: synth_series(pct),
      delta: "↑ 2.4%"
    }
  end

  def stat_memory
    used  = host_mem_used_gb
    total = host_mem_total_gb
    pct   = total.zero? ? 0 : (used / total * 100).round
    {
      label: "MEMORY", icon: :CircleStackOutline,
      value: format("%.1f", used), unit: "GB",
      sub: "of #{format('%.0f', total)} GB · #{pct}%",
      color: "var(--voodu-blue)",
      series: synth_series(pct),
      delta: "↑ 2.4%"
    }
  end

  # Disk I/O is fully mocked today (PAT plane doesn't surface it).
  def stat_disk
    mb_per_sec = 142
    {
      label: "DISK I/O", icon: :ServerStackOutline,
      value: mb_per_sec.to_s, unit: "MB/s",
      sub: "184 GB used of 500 GB",
      color: "var(--voodu-green)",
      series: synth_series(mb_per_sec / 2.0),
      delta: "↑ 2.4%"
    }
  end

  # Network throughput is fully mocked today.
  def stat_network
    {
      label: "NETWORK", icon: :SignalOutline,
      value: "38.6", unit: "Mbps",
      sub: "↑ 12.1  ↓ 26.5 Mbps",
      color: "var(--voodu-amber)",
      series: synth_series(38),
      delta: "↑ 2.4%"
    }
  end

  # ── Helpers ─────────────────────────────────────────────────────

  def host_cpu_pct
    @stats&.dig("host", "cpu_percent").to_f
  end

  def host_mem_used_gb
    bytes = @stats&.dig("host", "mem_used_bytes").to_f
    bytes / 1024**3
  end

  def host_mem_total_gb
    bytes = @stats&.dig("host", "mem_total_bytes").to_f
    bytes / 1024**3
  end

  # prepare_pod — normalise the PAT-plane pod record + decorate with
  # mocked fields the API doesn't expose yet.
  #
  # Carries the identity tuple (scope / resource_name / replica_id)
  # alongside the legacy `name` so the table can render the compound
  # display ("scope/name.replica") without re-parsing.
  #
  # Ports come from the enriched detail (the response now uses
  # ?detail=true): payload carries `ports: [{container: "80/tcp"}, …]`.
  # We extract the container number (before `/`) + dedup.
  def prepare_pod(p)
    status = pod_status_sym(p)

    {
      name:          p["name"],
      scope:         p["scope"],
      resource_name: p["resource_name"],
      replica_id:    p["replica_id"],
      kind:          p["kind"],
      image:         p["image"],
      status:        status,
      cpu_pct:       mock_pod_cpu(p),
      mem_used_mb:   mock_pod_mem(p)[:used],
      mem_total_mb:  mock_pod_mem(p)[:total],
      restarts:      mock_pod_restarts(p),
      age:           format_age(p["created_at"]),
      ports:         extract_ports(p)
    }
  end

  # extract_ports — pulls unique container port numbers out of the
  # PodDetail payload. Input: `ports: [{"container": "80/tcp"}, ...]`.
  # Strips protocol suffix; dedupes preserving order. When ports
  # isn't present (compact response, or pod with no ports), returns [].
  def extract_ports(p)
    raw = Array(p["ports"])
    raw.filter_map do |entry|
      container = entry.is_a?(Hash) ? (entry["container"] || entry[:container]) : entry
      container.to_s.split("/").first.presence
    end.uniq
  end

  def pod_status_sym(p)
    return :running if p["running"]
    return :restarting if p["status"].to_s.match?(/restarting/i)

    :stopped
  end

  # Synthesise sparkline series — stable per current value so a
  # refresh that returns the same number doesn't redraw the curve.
  def synth_series(current)
    base = current.to_f.clamp(0, 100)
    rng = Random.new(base.round * 17 + 3)
    (0..28).map do |i|
      jitter = rng.rand(-8.0..8.0)
      ((base + jitter) + Math.sin(i / 4.0) * 5).clamp(0, 100)
    end + [base]
  end

  def mock_pod_cpu(p)
    # Deterministic by pod name so each row reads stable across refresh.
    return 0.0 unless p["running"]

    seed = p["name"].to_s.sum
    Random.new(seed).rand(0.5..28.0).round(1)
  end

  def mock_pod_mem(p)
    return { used: nil, total: nil } unless p["running"]

    seed = p["name"].to_s.sum + 1
    total = [256, 512, 768, 1024, 2048, 4096].sample(random: Random.new(seed))
    used  = Random.new(seed + 2).rand((total * 0.1).to_i..(total * 0.85).to_i)
    { used: used, total: total }
  end

  def mock_pod_restarts(p)
    seed = p["name"].to_s.sum + 3
    Random.new(seed).rand(0..12)
  end

  # mock_pod_ports — deleted. Ports come from `extract_ports(p)` now
  # that the WebUI calls `/pods?detail=true`. Method kept as `nil`
  # tombstone for grep history.
  def mock_pod_ports(_p) = []

  def format_age(created_at)
    return "—" if created_at.blank?

    t = Time.zone.parse(created_at.to_s)
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
