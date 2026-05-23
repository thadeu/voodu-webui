# frozen_string_literal: true

# PodDetailData — `/pods/:name` data assembler. Same cache contract
# as OverviewData (10s TTL per [island, pod_name]; ?refresh=1
# bypasses). The raw pod hash from the PAT plane is exposed verbatim
# via `raw` so Spec/Network/Env/Labels cards can render bypass — no
# field renaming, no curated subsets, no surprises.
#
# Decorations on top of the raw payload (the API doesn't ship them yet):
#   - 4 sparkline series for CPU / Memory / NetRx / NetTx, deterministic
#     per pod name so they don't flicker across refreshes.
#   - synth current values for the 4 stat cards' big numbers.
#
# When the cluster API eventually exposes real history, drop the
# `mock_*` calls below — view + cards keep working unchanged.
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

  # The four stat-card payloads (same shape Components::Overview::StatCard
  # consumes). Period "5m" — the detail view shows a finer-grained
  # window than the dashboard's "1h".
  def stat_cards
    [
      stat_card("CPU",    :CpuChipOutline,    "%.1f" % cpu_pct,  "%",    "last 5m",         "var(--voodu-accent)", cpu_pct),
      stat_card("MEMORY", :CircleStackOutline, mem_used.to_s,    mem_unit, mem_sub,         "var(--voodu-blue)",   mem_used.to_f),
      stat_card("NET RX", :SignalOutline,      "%.1f" % net_rx,  "Mbps", "inbound traffic", "var(--voodu-green)",  net_rx * 10),
      stat_card("NET TX", :SignalOutline,      "%.1f" % net_tx,  "Mbps", "outbound traffic","var(--voodu-amber)",  net_tx * 10)
    ]
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

  def stat_card(label, icon, value, unit, sub, color, base_for_series)
    {
      label:, icon:, value:, unit:, sub:, color:,
      period: "5m", delta: nil,
      series: synth_series(base_for_series)
    }
  end

  # ── Mock decorations (deterministic per pod name) ───────────────

  def seed = @name.to_s.sum

  def cpu_pct
    return 0.0 unless status_sym == :running

    Random.new(seed).rand(0.5..28.0)
  end

  def mem_used
    return 0 unless status_sym == :running

    Random.new(seed + 1).rand(32..256)
  end

  def mem_total
    return nil unless status_sym == :running

    [256, 512, 1024].sample(random: Random.new(seed + 2))
  end

  def mem_unit
    return "" if mem_total.nil?

    "/ #{mem_total} MB"
  end

  def mem_sub
    return "pod stopped" if status_sym != :running
    return "—" if mem_total.nil? || mem_total.zero?

    pct = (mem_used.to_f / mem_total * 100).round

    "#{pct}% of limit"
  end

  def net_rx
    return 0.0 unless status_sym == :running

    (cpu_pct * 0.6).round(1)
  end

  def net_tx
    return 0.0 unless status_sym == :running

    (cpu_pct * 0.3).round(1)
  end

  def synth_series(base)
    b = base.to_f.clamp(0, 100)
    rng = Random.new(b.round * 17 + 3 + seed)
    (0..38).map do |i|
      jitter = rng.rand(-6.0..6.0)
      ((b + jitter) + Math.sin(i / 4.0) * 4).clamp(0, 100)
    end + [b]
  end

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
