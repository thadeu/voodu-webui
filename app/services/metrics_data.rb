# frozen_string_literal: true

# MetricsData — chart-ready time-series fetcher with per-card cache.
#
# OverviewData and PodDetailData call MetricsData.new(client, island)
# once per request, then ask for `series_for(...)` per StatCard.
# Misses go to the controller's /metrics endpoint; hits return
# instantly from Rails.cache (60s TTL — charts rarely move that fast).
#
# Cache TTL is intentionally LONGER than the sampler's 15s cadence:
# operators looking at a 1h chart don't notice the difference between
# 60s-old and live data, and the per-island request volume drops by
# ~4× on a busy session.
#
# Per-card / per-pod cache keys mean two operators (or two browser
# tabs) hitting the same chart share the cached fetch — same pattern
# as IslandHealth + pods_count.
class MetricsData
  # Pinned 4s SHORTER than MetricsSyncIslandJob's 14s recurring
  # cadence (see config/recurring.yml). The gap guarantees: whenever
  # the job ticks at T and broadcasts metrics_tick, the cache cell
  # populated at the previous tick (T−14s) has already expired
  # (T−4s past TTL). Frame.reload() always cache-misses and pulls
  # fresh data. Going EQUAL or HIGHER reintroduces the "served
  # previous tick's data" bug operators observed as "2min sem
  # atualizar."
  CACHE_TTL = 10.seconds

  def initialize(client, island)
    @client = client
    @island = island
  end

  # points_for — returns rich points `[{ts:, value:, formatted:}]`
  # the new Sparkline consumes. Each point carries the original
  # timestamp + value + a human-readable string formatted for the
  # metric (`12.5%`, `512 MB`, `1.2 GB`, …) so the hover tooltip
  # doesn't have to know whether the metric is a percentage or a
  # byte count — that knowledge lives here, where the metric name
  # is in scope.
  #
  # Returns `[]` on any failure (controller offline, metric
  # unknown, etc.) so callers' `if points.present?` guard in the
  # view degrades cleanly to "show the headline number, no chart."
  def points_for(source:, metric:, range: "1h", interval: "auto", scope: nil, name: nil, pod: nil)
    return [] unless data_source_available?

    payload = fetch(source: source, metric: metric, range: range, interval: interval, scope: scope, name: name, pod: pod)
    return [] unless payload.is_a?(Hash)

    formatter = formatter_for(metric)

    points = Array(payload["series"]).map do |p|
      val = p["value"].to_f
      {
        ts:        p["ts"],
        value:     val,
        formatted: formatter.call(val)
      }
    end

    # Append the LATEST sample as the rightmost point. Reads from
    # the shared latest cache (NOT payload["latest"]) so the chart's
    # last dot is the same value across every range pill — the
    # bucketed series may have been cached against this range
    # 60s ago, while a different range pill just refreshed the
    # shared latest 5s ago. Always using the shared cell keeps
    # headline + rightmost dot in lock-step across ranges.
    #
    # Skip when no latest is cached (cold boot before first fetch)
    # or when its ts isn't newer than the last bucket point — no
    # gain from duplicating. Hover tooltip shows the unaggregated
    # value with its real timestamp.
    if (latest_record = read_shared_latest(source, metric, scope, name, pod))
      last_bucket_ts = points.last && points.last[:ts]

      if last_bucket_ts.nil? || latest_record[:ts] > last_bucket_ts
        points << {
          ts:        latest_record[:ts],
          value:     latest_record[:value],
          formatted: formatter.call(latest_record[:value])
        }
      end
    end

    points
  end

  # series_for — legacy shape: bare `[Float]` for callers that
  # haven't moved to points_for yet. Kept so the migration to the
  # rich Sparkline can land in one repo without breaking
  # intermediate states. New code should prefer points_for.
  def series_for(source:, metric:, range: "1h", interval: "auto", scope: nil, name: nil, pod: nil)
    points_for(source: source, metric: metric, range: range, interval: interval, scope: scope, name: name, pod: pod)
      .map { |p| p[:value] }
  end

  # latest_for — the SINGLE most recent unaggregated sample,
  # independent of range. Reads from a SHARED cache cell so that
  # 1h and 6h pills serve the same number — without this, each
  # range had its own cache entry captured at a different moment
  # and the headline jumped 8.6 ↔ 9.3 just by switching pills.
  #
  # If the shared cell is empty (cold boot before first
  # /metrics fetch), this method triggers a fetch which side-
  # effects the shared cell, then reads it.
  #
  # Returns the raw Float or nil when there's no data.
  def latest_for(source:, metric:, range: "1h", interval: "auto", scope: nil, name: nil, pod: nil)
    return nil unless data_source_available?

    if (rec = read_shared_latest(source, metric, scope, name, pod))
      return rec[:value]
    end

    # Cold miss: fall through to range-based fetch — its `fetch`
    # side-effect populates the shared cell. Subsequent reads
    # from any range hit the populated cell.
    fetch(source: source, metric: metric, range: range, interval: interval, scope: scope, name: name, pod: pod)

    rec = read_shared_latest(source, metric, scope, name, pod)
    rec && rec[:value]
  end

  # raw_payload exposes the full envelope (series + interval + truncated
  # flags) when a caller needs the metadata, not just the values. Used
  # by future pages that render the chart axis explicitly.
  def raw_payload(source:, metric:, range: "1h", interval: "auto", scope: nil, name: nil)
    return nil unless data_source_available?

    fetch(source: source, metric: metric, range: range, interval: interval, scope: scope, name: name)
  end

  private

  # formatter_for — returns a callable that renders a metric value
  # as the operator-readable string the tooltip shows. Decisions
  # match the StatCard headline units (pod show: cpu_sub shows
  # `limit 0.5`; mem_used_label shows `512 MB` — tooltip must
  # speak the same dialect).
  #
  # Centralising here means a new metric needs ONE change (this
  # case statement) — Sparkline / Stimulus don't know about units.
  def formatter_for(metric)
    case metric
    when "cpu_percent"
      # Adaptive precision — sub-1% values keep 2 decimals so an
      # idle pod doesn't read as a flat "0.0%" line. See
      # MetricFormat for the magnitude tiers.
      MetricFormat.method(:percent)

    when /\Areq_/
      # HTTP request counters — integers. Tooltip shows "184 reqs"
      # instead of "184.0", matching how the headline reads.
      ->(v) { v.to_i.to_s }

    when /_ms\z/
      # Latency in milliseconds. 2 decimals so sub-ms (cached static
      # responses) doesn't collapse to "0 ms".
      ->(v) { "#{v.round(2)} ms" }

    when /\Amem_/, /\Adisk_/
      method(:format_bytes)

    when /_delta_bytes\z/
      # Delta-per-tick rate — show as bytes/15s? Keep absolute
      # bytes for now since the chart timeline already implies the
      # period; user reads "100 MB in this bucket" naturally.
      method(:format_bytes)

    when /_bytes\z/, "bytes_out"
      method(:format_bytes)

    else
      ->(v) { v.round(2).to_s }
    end
  end

  # format_bytes — decimal kB/MB/GB matching `docker stats` (the
  # CLI operators already use). Mirror of PodDetailData#format_bytes
  # because tooltip rendering goes through this service.
  def format_bytes(b)
    b = b.to_f
    return "0 B"                                       if b.zero?
    return "#{b.round} B"                              if b < 1_000
    return "#{(b / 1_000.0).round(1)} kB"              if b < 1_000_000
    return "#{(b / 1_000_000.0).round(1)} MB"          if b < 1_000_000_000
    return "#{(b / 1_000_000_000.0).round(1)} GB"      if b < 1_000_000_000_000

    "#{(b / 1_000_000_000_000.0).round(1)} TB"
  end

  # fetch — Rails.cache-backed wrapper around the metric data source.
  #
  # TWO backends, selected per-request by the WAREHOUSE env:
  #
  #   - HTTP path (default): calls Voodu::Client#metrics, which
  #     round-trips to the controller's /api/pat/v1/metrics and
  #     scans the NDJSON files on disk. The legacy + correct-by-
  #     default path; flipping the env back to false instantly
  #     restores this behaviour.
  #
  #   - Warehouse path (ENV["WAREHOUSE"]=true): calls
  #     MetricsWarehouse.query, which serves the SAME envelope from
  #     the local `metrics` SQLite database (populated by the
  #     MetricsSync jobs every 30s).
  #
  # Why a per-request flag instead of a hard switch?
  #
  #   - A/B compare: operator runs `WAREHOUSE=true bin/dev`
  #     in one terminal, plain `bin/dev` in another, opens the same
  #     page in both. Bytes-for-bytes comparison.
  #   - Rollback is reverting one env var — no schema undo, no
  #     code revert.
  #   - The cache key includes the backend tag so flipping the flag
  #     doesn't serve a stale entry from the other backend.
  #
  # Errors are swallowed (return nil) so a flaky chart doesn't
  # poison the parent OverviewData/PodDetailData fetch. Both
  # backends raise different exception families (Voodu::Client::Error
  # for HTTP; ActiveRecord::StatementInvalid for SQLite) — the
  # rescue list covers both.
  def fetch(source:, metric:, range:, interval:, scope:, name:, pod:)
    # One hash carries ALL params; the cache key digests it. Adding
    # a new param (`agg=max`, `format=json`, …) becomes a one-line
    # change here — no separate cache_key signature to update.
    query = {
      source: source, metric: metric, range: range, interval: interval,
      scope: scope, name: name, pod: pod
    }

    Rails.cache.fetch(cache_key(query), expires_in: CACHE_TTL) do
      payload =
        if warehouse_enabled?
          MetricsWarehouse.query(@island, **query)
        else
          @client.metrics(**query)
        end

      # Side-effect: publish the latest to the SHARED cell so all
      # other range pills + latest_for() see the same value.
      # MUST be inside the cache.fetch block so we only write on
      # miss; writing on cache-hit would overwrite a fresher
      # shared latest (from another range's fetch) with our own
      # stale payload, defeating the whole point of the shared
      # cell.
      if payload.is_a?(Hash) && (latest = payload["latest"]).is_a?(Hash) && latest["ts"].present?
        Rails.cache.write(
          latest_cache_key(identity_from(query)),
          { ts: latest["ts"], value: latest["value"].to_f },
          expires_in: CACHE_TTL
        )
      end

      payload
    end
  rescue Voodu::Client::Error, ActiveRecord::StatementInvalid => e
    Rails.logger.warn("metrics: #{source}/#{metric} #{range}: #{e.class} #{e.message}")
    nil
  end

  # warehouse_enabled? — env-flag gate. Boolean string ("true" / "1")
  # so a shell `export WAREHOUSE=true` flips the path. Empty
  # / "false" / "0" / unset → HTTP path (default).
  #
  # Checked per request (not memoised) so a process can toggle the
  # flag mid-flight via Rails.application.config or a hot-reload
  # without restart. Cost is one ENV lookup per chart, negligible.
  def warehouse_enabled?
    %w[true 1].include?(ENV["WAREHOUSE"].to_s.downcase)
  end

  # data_source_available? — guards the public methods against the
  # "neither backend usable" case:
  #
  #   - HTTP path needs @client (built from @island.endpoint+pat).
  #   - Warehouse path needs only @island (used as tenant_id key)
  #     because reads hit local SQLite, not the network.
  #
  # When the warehouse is enabled but @island is also nil (would
  # only happen on tenant-less routes that build MetricsData wrong),
  # we still short-circuit — there's nothing to query against.
  def data_source_available?
    if warehouse_enabled?
      !@island.nil?
    else
      !@client.nil?
    end
  end

  # read_shared_latest — reads the no-range, no-interval cache cell
  # populated by `fetch` as a side-effect. Returns `{ts:, value:}`
  # or nil. Used by both latest_for (headline) and points_for
  # (chart's appended rightmost dot) so both surfaces show the
  # same number regardless of which range pill the operator is on.
  def read_shared_latest(source, metric, scope, name, pod)
    Rails.cache.read(latest_cache_key(
      source: source, metric: metric, scope: scope, name: name, pod: pod
    ))
  end

  # ── Cache keys (content-addressed) ─────────────────────────────
  #
  # Both keys are SHA256(sorted query) prefixed with a namespace +
  # island id. Two requests with the SAME params (regardless of
  # hash order) hit the same cell; ANY param change invalidates
  # cleanly. Adding a new query param requires zero changes here.

  # Cache key includes the backend tag so flipping WAREHOUSE
  # mid-session doesn't serve a stale entry from the other backend
  # (subtly different floats from rounding paths would make the
  # debug confusing — separate cells keep the A/B clean).
  def cache_key(query)
    backend = warehouse_enabled? ? "wh" : "http"
    "voodu:metrics:v1:#{backend}:island:#{@island.id}:#{digest(query)}"
  end

  def latest_cache_key(identity)
    "voodu:metrics_latest:v1:island:#{@island.id}:#{digest(identity)}"
  end

  # identity_from — strips the range/interval (and any future
  # bucket-shape param) from a query, leaving only the fields
  # that identify WHICH series the latest belongs to. That's
  # what makes the shared latest stable across range pills.
  IDENTITY_KEYS = %i[source metric scope name pod].freeze

  def identity_from(query)
    query.slice(*IDENTITY_KEYS)
  end

  # digest — stable hash of a params hash. Sorts keys + drops nils
  # before serialising so:
  #   - {a:1,b:2} and {b:2,a:1} produce the same digest
  #   - {a:1,b:nil} and {a:1} produce the same digest (consistent
  #     handling of "param not set")
  # 16 hex chars (64 bits) is plenty for collision-resistance at
  # the scale of cache entries we'll ever hold.
  def digest(params)
    normalized = params.compact.transform_keys(&:to_s).sort.to_h.to_query
    Digest::SHA256.hexdigest(normalized)[0, 16]
  end

end
