# frozen_string_literal: true

# OverviewData prepares the shape the Overview view consumes — a
# single decoded bundle the view can render without per-section
# decision logic.
#
# Real data (from the PAT plane):
#   - host CPU%, memory, cores, load averages, uptime — /system
#   - disk usage, disk I/O rate, network throughput   — /system
#   - pod list (name, image, running, ports, …)       — /pods?detail=true
#
# Mocked (until the PAT plane exposes the field):
#   - sparkline time series — synthesised from current value
#     (server doesn't keep history; future M will persist a ring
#     buffer or push to a TS DB)
#   - per-pod CPU%, memory used/total, restarts — synthetic
#     (the controller's /stats has these per-pod but joining it with
#     the detail listing is the next parity milestone)
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
    @system     = nil
    @pods_raw   = []
    @updated_at = Time.current
    @error      = nil
    @cache_hit  = false
    @metrics    = MetricsData.new(client, island)
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

  # Stat-card payloads — passed straight as kwargs to
  # Components::Overview::StatCard.new(...).
  #
  # Three cards in W7+: CPU / MEMORY / DISK. The NETWORK card was
  # removed because host-level network rate (the sum over all NICs)
  # double-counts container traffic (eth0 → docker0 → veth*) and
  # rarely told the operator anything actionable. Per-pod NET I/O
  # lives on the pod show page now, where it's authoritative
  # (`docker stats` per-container counters).
  #
  # The DISK card also changed shape: previously showed "I/O MB/s"
  # (which was rate-from-deltas and rarely the question being asked)
  # — now shows "X GB used of Y GB" (the "is the box about to run
  # out of disk?" question that actually matters).
  def stat_cards
    [
      stat_cpu, stat_memory, stat_disk
    ]
  end

  # uptime_seconds — host uptime since boot, from /system. Returns
  # 0 when the system payload isn't available (controller offline,
  # not yet wired). The topbar formats it as "41d 2h" etc.
  def uptime_seconds
    @system&.dig("host", "uptime_seconds").to_i
  end

  # uptime_label — humanized topbar chip ("41d 2h", "3h 12m",
  # "47s"). Renders "—" when uptime is 0 (no data yet) so the
  # operator sees something explicit rather than "0s".
  def uptime_label
    s = uptime_seconds
    return "—" if s <= 0

    days  = s / 86_400
    hours = (s % 86_400) / 3600
    mins  = (s % 3600) / 60

    return "#{days}d #{hours}h" if days.positive?
    return "#{hours}h #{mins}m" if hours.positive?
    return "#{mins}m"           if mins.positive?

    "#{s}s"
  end

  # boot_time — ISO timestamp the host booted at. Used as a tooltip
  # alongside the chip so operators can see the absolute moment if
  # the relative label is ambiguous ("41d 2h since when?").
  def boot_time
    @system&.dig("host", "boot_time")
  end

  # kernel — informational only; surfaced in a future "host details"
  # popover. Available now so the wire fields don't go unused.
  def kernel
    @system&.dig("host", "kernel")
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

  # Host facts surfaced in the subtitle / topbar. All sourced from
  # /system now (gopsutil-backed). Zero when /system isn't reachable
  # — renders as "—" in the view rather than fabricated numbers.
  def cores
    @system&.dig("cpu", "cores").to_i
  end

  def load_1  = round_load(@system&.dig("cpu", "load_1"))
  def load_5  = round_load(@system&.dig("cpu", "load_5"))
  def load_15 = round_load(@system&.dig("cpu", "load_15"))

  private

  def round_load(v)
    return 0.0 if v.nil?

    v.to_f.round(2)
  end

  # fetch! — pulls the (system + pods) snapshot via Rails.cache.
  #
  #   - Cache HIT  → no network. Snapshot is reused; @cache_hit = true.
  #                  @updated_at carries the original fetch time so the
  #                  topbar's "updated Ns ago" pill reflects data
  #                  freshness, not page render time.
  #   - Cache MISS → one /system + one /pods?detail=true call to the
  #                  PAT plane. Both responses cached under a
  #                  per-island key.
  #   - force_refresh → cache invalidated up front (the "Refresh all"
  #                  button passes `?refresh=1`).
  #   - Voodu::Client::Error → stored on @error and NOT cached. The
  #                  next request retries immediately rather than
  #                  serving a stale failure for TTL seconds.
  #
  # Note on /system being request-driven, not background: the IO+Net
  # rates are server-side deltas between consecutive calls. With our
  # 10s cache TTL, every page load past TTL forces a fresh sample,
  # so the rates settle into a real average across the operator's
  # actual page-view cadence rather than a synthetic ticker. The
  # first page load after controller boot shows 0 for IO/Net — the
  # second shows real rates. We document this in the WebUI badge
  # ("warming up" hint is a future polish).
  def fetch!
    return if @client.nil?

    Rails.cache.delete(cache_key) if @force

    cached = Rails.cache.read(cache_key)
    if cached
      @cache_hit  = true
      @system     = cached[:system]
      @pods_raw   = cached[:pods]
      @updated_at = cached[:fetched_at]
      return
    end

    @system = @client.system
    # detail=true asks the controller for the enriched list (ports,
    # env, networks, restart_policy …). Same payload `vd describe pod`
    # consumes. The CLI/WebUI parity work guarantees the response is
    # byte-identical across the two planes.
    @pods_raw   = @client.pods(detail: true)["pods"] || []
    @updated_at = Time.current

    Rails.cache.write(
      cache_key,
      { system: @system, pods: @pods_raw, fetched_at: @updated_at },
      expires_in: CACHE_TTL
    )

    # Successful fetch == controller is reachable + PAT is valid +
    # process is alive. Warm the IslandHealth cache so the sidebar
    # and topbar render :online without spending their own probe.
    IslandHealth.warm(@island, online: true)

    # Warm the sidebar's pods-count badge ("0 pods" → real count).
    # TTL slightly longer than the snapshot's 10s so the sidebar
    # doesn't briefly blank out between page renders within the
    # same browsing session. Stale-after-expiry behaviour is OK
    # because the next overview render rewrites it.
    Island.write_pods_count(@island, @pods_raw.size)

    # Warm the topbar's uptime chip. Same cache pattern — every
    # page (Pods, Logs, pod show, …) reads from this key without
    # needing to fetch /system itself. Without this warm, the
    # topbar uptime would show "—" on every non-Overview page.
    Island.write_uptime_seconds(@island, uptime_seconds)
  rescue Voodu::Client::Error => e
    # Don't poison the cache with a failure — let the next request
    # retry. Operators iterating on a misconfigured PAT shouldn't have
    # to wait TTL seconds to see their fix take effect.
    @error = e

    # The error still tells us something: this island isn't reachable
    # right now. Flip the health cache to :offline so the sidebar /
    # topbar reflects the symptom without triggering a redundant
    # probe of their own.
    IslandHealth.warm(@island, online: false)
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
      sub: cores.positive? ? "#{cores} cores · load #{load_1}" : "—",
      color: "var(--voodu-accent)",
      series: @metrics.series_for(source: :system, metric: "cpu_percent", range: "1h"),
      delta: nil
    }
  end

  def stat_memory
    used  = host_mem_used_gb
    total = host_mem_total_gb
    pct   = total.zero? ? 0 : (used / total * 100).round
    {
      label: "MEMORY", icon: :CircleStackOutline,
      value: format("%.1f", used), unit: "GB",
      sub: total.positive? ? "of #{format('%.0f', total)} GB · #{pct}%" : "—",
      color: "var(--voodu-blue)",
      series: @metrics.series_for(source: :system, metric: "mem_used_bytes", range: "1h"),
      delta: nil
    }
  end

  # Disk card — usage only. Headline is the used count, sub-line
  # is the limit + percent. /system payload carries disk[] (slice
  # for forward-compat with multi-mount); we surface the first
  # entry, which is `/` (the root mount, the universally-meaningful
  # one). Future multi-mount expansion adds a picker; shape stays.
  def stat_disk
    used  = disk_used_gb
    total = disk_total_gb
    pct   = total.zero? ? 0 : (used.to_f / total * 100).round
    {
      label: "DISK", icon: :ServerStackOutline,
      value: used.to_s, unit: "GB",
      sub: total.positive? ? "of #{total} GB · #{pct}%" : "—",
      color: "var(--voodu-green)",
      series: @metrics.series_for(source: :system, metric: "disk_used_bytes", range: "1h"),
      delta: nil
    }
  end

  # ── Helpers ─────────────────────────────────────────────────────

  # host_cpu_pct — aggregate CPU% across all cores. Sourced from
  # /system (cpu.percent). First call after controller boot returns
  # 0 (gopsutil needs two samples to compute the delta); subsequent
  # calls return the real percentage.
  def host_cpu_pct
    @system&.dig("cpu", "percent").to_f
  end

  # host_mem_* — total/used RAM in GB. Conversion uses GiB (1024^3)
  # to match `htop` / `free -h` semantics: an operator looking at
  # "16 GB" in the StatCard expects that to match what their tooling
  # reports for the same machine.
  def host_mem_used_gb
    bytes = @system&.dig("mem", "used_bytes").to_f
    bytes / 1024**3
  end

  def host_mem_total_gb
    bytes = @system&.dig("mem", "total_bytes").to_f
    bytes / 1024**3
  end

  # Disk helpers — the controller's /system returns disk[] (a slice
  # for forward compat). We surface the first entry — currently `/`,
  # the universally-meaningful one. Future multi-mount support adds
  # a picker; the shape stays.
  def disk_used_gb
    bytes = @system&.dig("disk", 0, "used_bytes").to_f
    (bytes / 1024**3).round
  end

  def disk_total_gb
    bytes = @system&.dig("disk", 0, "total_bytes").to_f
    (bytes / 1024**3).round
  end

  # disk_io_total_bytes_per_sec — deleted in W7. Host-level disk
  # I/O rate was removed from /system because the rate-from-deltas
  # approach was confusing (mix of physical + LVM + loop devices),
  # and "is the disk filling up?" — the question operators
  # actually ask — is answered by disk_used_gb/disk_total_gb.
  # Per-pod block I/O is now on UsageStats; pod show renders it.

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
      cpu_pct:       extract_cpu_pct(p),
      mem_used_mb:   extract_mem_mb(p, "memory_usage_bytes"),
      mem_total_mb:  extract_mem_mb(p, "memory_limit_bytes"),
      age:           format_age(p["created_at"]),
      ports:         extract_ports(p)
    }
  end

  # extract_cpu_pct — real per-container CPU% from the stats block
  # the controller now joins into /pods?detail=true. Path:
  #   pod.stats.usage.cpu_percent  (float, 0..100ish)
  #
  # Returns 0.0 when the stats block is absent — happens for stopped
  # pods (no live cgroup), orphan pods filtered out by the collector,
  # or in the brief window after the controller starts and before
  # the docker stats daemon has its first sample.
  def extract_cpu_pct(p)
    p.dig("stats", "usage", "cpu_percent").to_f.round(1)
  end

  # extract_mem_mb — converts a bytes value at the given JSON path
  # into MB (1024-based, matching `free -m` and the StatCard header
  # convention) rounded to the integer the table renders. Returns
  # nil when the path is absent so the renderer can show "—"
  # instead of "0 MB" for stopped/orphan pods.
  def extract_mem_mb(p, key)
    bytes = p.dig("stats", "usage", key)
    return nil if bytes.nil? || bytes.to_i.zero?

    (bytes.to_f / (1024 * 1024)).round
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

  # synth_series — deleted in M2.C4. Real time-series via
  # MetricsData replaced this; when /metrics returns empty (cold
  # boot, controller offline, no data yet) the StatCard's own
  # `return if @series.blank?` guard hides the sparkline cleanly.
  # Honest empty state > fake fluctuation.

  # mock_pod_cpu / mock_pod_mem — deleted. Per-pod CPU% and memory
  # usage come from the joined `stats` block in /pods?detail=true
  # now (see extract_cpu_pct / extract_mem_mb above). The controller
  # runs one batch `docker stats` sample as part of the enrichment
  # and attaches the result to each PodDetail — fixed cost regardless
  # of pod count.

  # mock_pod_restarts — deleted. The "restarts" column was removed
  # from PodsTable + PodCard; once the controller surfaces a real
  # per-replica restart count via /pods?detail=true, both the wire
  # field and the column come back together.

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
