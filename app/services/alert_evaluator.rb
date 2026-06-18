# frozen_string_literal: true

# AlertEvaluator — checks every enabled rule of one island against
# the local metrics warehouse and drives the fire → resolve state
# machine. Runs every 30s via AlertsEvaluationIslandJob; everything
# here is local SQLite, no controller HTTP.
#
# Timing model (why the window is anchored where it is):
#
#   controller sampler tick   15s
#   warehouse sync tick       14s
#   ⇒ the newest warehouse bucket trails wall-clock by up to ~30s.
#
# Anchoring the sustained-for window at Time.current would therefore
# always include 1-2 not-yet-synced buckets and the all-buckets-
# breaching test could never pass. Instead the window ends at the
# NEWEST AVAILABLE bucket and reaches back `duration_seconds` from
# there. Detection latency = duration + (sync lag + eval cadence),
# ≈ duration + 45s worst case.
#
# Missing data is never an opinion: an empty or stale series neither
# fires (no false positives while an island is offline) nor resolves
# (a firing alert holds, surfaced as last_status "stale", until real
# samples say otherwise).
class AlertEvaluator
  # Warehouse bucket width AND the floor for the observed sample
  # cadence. The local sampler ticks every 15s, but a remote island
  # can deliver pod/system samples far more sparsely (e.g. every
  # ~210s). Everything time-sensitive below scales off the cadence
  # ESTIMATED from the data (cadence_for), not this fixed value — so a
  # coarse-cadence island isn't permanently "NO DATA"/"stale".
  BUCKET_SECONDS = 15

  # Minimum lookback for the warehouse query. Must be wide enough to
  # see SEVERAL samples even on a coarse-cadence island, otherwise we
  # can't estimate the cadence (or even find a fresh sample) for a
  # short-duration rule. 15min captures ~4 samples at a 210s cadence.
  MIN_LOOKBACK = 15 * 60

  # Extra range on top of duration (for long-duration rules where
  # duration + slack already exceeds MIN_LOOKBACK).
  WINDOW_SLACK = 120

  # Staleness floor + multiplier. The newest sample is stale when it's
  # older than max(STALE_FLOOR, cadence × STALE_CADENCES). Dense island
  # (cadence 15s) ⇒ 90s; coarse island (cadence 210s) ⇒ ~10.5min, so a
  # normal 206s-old sample reads as FRESH, not offline.
  STALE_FLOOR = 90
  STALE_CADENCES = 3

  # Fraction of EXPECTED samples (duration ÷ cadence) that must exist
  # in the window before we trust an all-breaching verdict — always at
  # least 1. Below it: no_data, not firing.
  MIN_COVERAGE = 0.6

  # Hysteresis: this many consecutive trailing samples must be clean
  # before a firing alert resolves — keeps a value oscillating around
  # the threshold from flapping the badge.
  RESOLVE_SAMPLES = 3

  # Same cutoff MetricsPageData#capacity_for_pod uses: above 1 TiB the
  # cgroup "limit" is docker's kernel-max sentinel (no limit set), and
  # a percentage against it would be meaningless noise.
  MEMORY_LIMIT_SENTINEL = 1_099_511_627_776

  def self.run(island)
    new(island).run
  end

  def initialize(island)
    @island = island
  end

  # Returns the number of fire/resolve transitions this tick (job log).
  def run
    transitions = 0

    @island.alert_rules.enabled.find_each do |rule|
      transitions += 1 if evaluate(rule)
    rescue => e
      Rails.logger.warn(
        "alerts-eval rule=#{rule.id} #{rule.name.inspect} failed: #{e.class}: #{e.message}"
      )
      mark_no_data(rule)
    end

    transitions
  end

  private

  def evaluate(rule)
    series = fetch_series(rule)

    return mark_no_data(rule) if series.empty?

    cadence = cadence_for(series)
    last_value = series.last[:value]

    return mark_no_data(rule, last_value: last_value) if stale?(series, cadence)

    window = window_for(rule, series)

    return mark_no_data(rule, last_value: last_value) if window.size < min_samples(rule, cadence)

    transitioned = false

    if rule.firing?
      if series.last(RESOLVE_SAMPLES).none? { |p| breach?(rule, p[:value]) }
        resolve!(rule, last_value)
        transitioned = true
      else
        refresh_open_event(rule, window, last_value)
      end
    elsif window.all? { |p| breach?(rule, p[:value]) }
      fire!(rule, window, last_value)
      transitioned = true
    end

    rule.update_columns(
      last_evaluated_at: Time.current,
      last_value: last_value,
      last_status: rule.firing? ? "firing" : "ok"
    )
    transitioned
  end

  # ---- state machine -------------------------------------------------

  def breach?(rule, value)
    (rule.comparator == "gte") ? value >= rule.threshold : value <= rule.threshold
  end

  def fire!(rule, window, last_value)
    started_at = Time.zone.at(window.first[:epoch])
    event = nil

    rule.transaction do
      # Re-check enabled inside the transaction: the operator may have
      # paused (or deleted) this rule in the web process between when
      # run() snapshotted the enabled set and now. Without this, fire!
      # would strand a firing event on a disabled rule that the
      # `enabled` scope then never re-evaluates (permanent red card).
      return false unless AlertRule.where(id: rule.id, enabled: true).exists?

      event = rule.alert_events.create!(
        island: @island,
        state: "firing",
        started_at: started_at,
        threshold: rule.threshold,
        rule_name: rule.name,
        metric_kind: rule.metric_kind,
        target_label: rule.target_label,
        peak_value: worst_value(rule, window),
        last_value: last_value
      )
      rule.update_columns(firing: true, firing_since: started_at)
    end

    AlertsLive.broadcast(@island)
    AlertNotifier.enqueue(event, "firing") if event
  rescue ActiveRecord::RecordNotUnique
    # A concurrent tick already opened the episode (partial unique
    # index on one-firing-per-rule). Adopt its verdict — and don't
    # notify; the tick that actually created the event already did.
    rule.update_columns(firing: true, firing_since: started_at)
  end

  def resolve!(rule, last_value)
    event = rule.open_event

    rule.transaction do
      event&.update!(
        state: "resolved",
        resolved_at: Time.current,
        last_value: last_value
      )
      rule.update_columns(firing: false, firing_since: nil)
    end

    AlertsLive.broadcast(@island)
    AlertNotifier.enqueue(event, "resolved") if event
  end

  # While an episode stays open, keep its live numbers honest so the
  # firing card shows the current + worst value without a transition.
  def refresh_open_event(rule, window, last_value)
    event = rule.open_event
    return if event.nil?

    worst = worst_value(rule, window)
    peak = if rule.comparator == "gte"
      [event.peak_value, worst].compact.max
    else
      [event.peak_value, worst].compact.min
    end

    event.update_columns(last_value: last_value, peak_value: peak)
  end

  # "Worst" is comparator-relative: highest for ≥ rules, lowest for ≤.
  def worst_value(rule, window)
    values = window.map { |p| p[:value] }

    (rule.comparator == "gte") ? values.max : values.min
  end

  def mark_no_data(rule, last_value: nil)
    # Preserve the last known value when a firing rule goes stale —
    # blanking it to nil would make the firing card render "—" for a
    # rule that's still considered firing. Only overwrite when we
    # actually have a fresh reading.
    attrs = {last_evaluated_at: Time.current, last_status: rule.firing? ? "stale" : "no_data"}
    attrs[:last_value] = last_value unless last_value.nil? && rule.firing?

    rule.update_columns(attrs)
    false
  end

  # cadence_for — the typical gap between samples, estimated from the
  # series (median, so a single long gap doesn't skew it), floored at
  # BUCKET_SECONDS. Drives staleness + coverage so the evaluator
  # adapts to whatever cadence an island actually delivers.
  def cadence_for(series)
    return BUCKET_SECONDS if series.size < 2

    gaps = series.each_cons(2).map { |a, b| b[:epoch] - a[:epoch] }.reject(&:zero?).sort
    return BUCKET_SECONDS if gaps.empty?

    [gaps[gaps.size / 2], BUCKET_SECONDS].max
  end

  def stale?(series, cadence)
    Time.current.to_i - series.last[:epoch] > [STALE_FLOOR, cadence * STALE_CADENCES].max
  end

  def window_for(rule, series)
    window_end = series.last[:epoch]

    series.select { |p| p[:epoch] > window_end - rule.duration_seconds }
  end

  # Minimum samples required in the window — a fraction of the expected
  # count (duration ÷ cadence), but never fewer than 1. On a coarse
  # island where cadence > duration, the window holds just the newest
  # sample and that single fresh reading is enough to act on.
  def min_samples(rule, cadence)
    expected = rule.duration_seconds.to_f / cadence

    [(expected * MIN_COVERAGE).ceil, 1].max
  end

  # ---- series construction -------------------------------------------

  # Returns [{epoch:, value:}, ...] oldest→newest, already converted
  # to the rule's display unit (% or req/s). Empty array = no data.
  def fetch_series(rule)
    case rule.metric_kind
    when "cpu" then cpu_series(rule)
    when "memory" then memory_series(rule)
    when "disk" then disk_series(rule)
    when "req_s" then req_s_series(rule)
    else []
    end
  end

  def cpu_series(rule)
    source = rule.host_target? ? "system" : "pod"

    points(query(rule, source: source, metric: "cpu_percent"))
  end

  def memory_series(rule)
    if rule.host_target?
      total = host_capacity("mem", "total_bytes") ||
        latest_value(rule, source: "system", metric: "mem_total_bytes")
      return [] unless total&.positive?

      percent_points(query(rule, source: "system", metric: "mem_used_bytes"), total)
    else
      limit = latest_value(rule, source: "pod", metric: "mem_limit_bytes")
      return [] if limit.nil? || limit <= 0 || limit > MEMORY_LIMIT_SENTINEL

      percent_points(query(rule, source: "pod", metric: "mem_usage_bytes"), limit)
    end
  end

  def disk_series(rule)
    total = host_capacity("disk", 0, "total_bytes") ||
      latest_value(rule, source: "system", metric: "disk_total_bytes")
    return [] unless total&.positive?

    percent_points(query(rule, source: "system", metric: "disk_used_bytes"), total)
  end

  # req_count buckets are SUM-aggregated totals per 15s bucket; the
  # envelope's interval_seconds turns them into a per-second rate.
  def req_s_series(rule)
    envelope = query(rule, source: "ingress", metric: "req_count")
    interval = envelope["interval_seconds"].to_i
    return [] unless interval.positive?

    points(envelope).map { |p| {epoch: p[:epoch], value: p[:value] / interval} }
  end

  def query(rule, source:, metric:)
    MetricsWarehouse.query(
      @island,
      source: source,
      metric: metric,
      range: "#{[rule.duration_seconds + WINDOW_SLACK, MIN_LOOKBACK].max}s",
      interval: "#{BUCKET_SECONDS}s",
      scope: rule.host_target? ? nil : rule.target_scope,
      name: rule.host_target? ? nil : rule.target_name
    )
  end

  def latest_value(rule, source:, metric:)
    query(rule, source: source, metric: metric).dig("latest", "value")&.to_f
  end

  def points(envelope)
    Array(envelope["series"]).filter_map do |point|
      value = point["value"]
      next if value.nil?

      {epoch: Time.iso8601(point["ts"]).to_i, value: value.to_f}
    end
  end

  def percent_points(envelope, total)
    points(envelope).map { |p| {epoch: p[:epoch], value: p[:value] / total * 100.0} }
  end

  # Host capacity from the state-sync snapshot (fresh every 10-15s).
  # Falls back to the warehouse's own *_total_bytes latest sample at
  # the call sites when the snapshot hasn't landed yet.
  def host_capacity(*path)
    state.system&.dig(*path)&.to_f&.then { |v| v.positive? ? v : nil }
  end

  def state
    @state ||= IslandState.for(@island)
  end
end
