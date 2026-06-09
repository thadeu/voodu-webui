# frozen_string_literal: true

# LogSearchData — backs the /logs/analytics search surface. Wraps
# LogTail::Reader (the NDJSON warehouse scanner) and shapes ONE
# query's result set for the line-by-line results table.
#
# Different interaction from the live-tail Page: that one streams the
# newest lines forever; this is a one-shot query. The operator picks a
# time window + an optional full-text/regex needle + a pod scope, and
# we return a bounded, newest-first snapshot they can scroll, expand,
# drill into (Surrounding Logs), or export.
#
# Caps — this is an operator tool reading local files, not a public
# API, so we bound the work and stay honest about truncation:
#
#   PAGE_SIZE      — rows rendered per page. The table shows the newest
#                    PAGE_SIZE; "Load more" pages back through older
#                    lines (see #page / #has_more? / #remaining).
#   MATCH_SCAN_CAP — lines the Reader scans before we stop counting.
#                    When hit, `truncated?` is true and `matched` is a
#                    floor ("≥ N"); the UI nudges the operator to
#                    narrow the window / add a filter. Also the hard
#                    ceiling on how far Load more can page.
#
# Newest-first ordering caveat: LogTail::Reader yields chronologically
# PER POD, then moves to the next pod — so the raw yield is not
# globally time-sorted. We collect (bounded by MATCH_SCAN_CAP), sort by
# ts desc, then page-slice. Under heavy truncation the scan cap can
# fill before the last pod is reached, so "newest N" is best-effort
# rather than exact. Acceptable for a tool whose answer to "too many
# results" is "narrow the window" — documented so it isn't read as a
# bug.
class LogSearchData
  PAGE_SIZE      = 5_000
  MATCH_SCAN_CAP = 20_000

  # Selectable quick windows. Capped at the warehouse retention so a
  # preset can never promise data we already reaped (see
  # LogTail::FilePath::RETENTION_DAYS).
  RANGES = {
    "5m"  => 5.minutes,
    "30m" => 30.minutes,
    "1h"  => 1.hour,
    "3h"  => 3.hours,
    "12h" => 12.hours,
    "24h" => 24.hours
  }.freeze

  DEFAULT_RANGE = "30m"

  # Hard floor on `from` — never scan past what cleanup keeps.
  RETENTION = LogTail::FilePath::RETENTION_DAYS.days

  attr_reader :island

  # @param island [Island]
  # @param params [Hash] the operator's filter choices. Recognised keys
  #   (symbol or string): :range, :from, :until, :q, :regex, :pods.
  def initialize(island:, params: {})
    @island = island
    @params = normalize_params(params)
    @page   = [@params[:page].to_i, 1].max
  end

  # ── Query state (also consumed by the FilterBar so the UI and the
  # scan stay in lockstep) ──────────────────────────────────────────

  # range — preset key, or "custom". Once the operator picks Custom it
  # STAYS custom even if a from/until is missing — falling back to a
  # preset there silently discarded the operator's choice (the custom
  # inputs vanished on reload and the query quietly used 30m). A bare
  # from/until with no range also reads as custom. Unknown → default.
  def range
    @range ||= begin
      r = @params[:range].to_s
      if r == "custom" || (r.blank? && parsed_from)
        "custom"
      else
        RANGES.key?(r) ? r : DEFAULT_RANGE
      end
    end
  end

  def custom?
    range == "custom"
  end

  def from
    window.first
  end

  def until_
    window.last
  end

  # from_iso / until_iso — the resolved window as unambiguous UTC ISO
  # strings. The filter bar hands these to the log-analytics controller,
  # which converts them to the BROWSER's local zone before filling the
  # datetime-local inputs — so the round-trip is correct even when the
  # server's zone differs from the operator's (rendering a server-local
  # value into datetime-local would drift by the offset on each submit).
  def from_iso
    from.utc.iso8601(3)
  end

  def until_iso
    until_.utc.iso8601(3)
  end

  def pods
    @pods ||= Array(@params[:pods])
              .flat_map { |p| p.to_s.split(",") }
              .map(&:strip)
              .reject(&:blank?)
  end

  def all_pods?
    pods.empty?
  end

  def search
    @params[:q].to_s
  end

  def regex?
    truthy?(@params[:regex])
  end

  # ── Results ───────────────────────────────────────────────────────

  # rows — the current PAGE_SIZE slice of the newest-first result set.
  # Each row is a plain hash { ts:, pod:, stream:, level:, msg:, raw:,
  # parsed: }.
  def rows
    load!
    @all[(@page - 1) * PAGE_SIZE, PAGE_SIZE] || []
  end

  # matched — total lines that matched the filter (floored at
  # MATCH_SCAN_CAP). When truncated?, treat as "≥ matched".
  def matched
    load!
    @matched
  end

  # 1-based page currently rendered, and the next page for Load more.
  def page
    @page
  end

  def next_page
    @page + 1
  end

  # has_more? — are there older matched lines past the current page
  # (within the scanned set)? Drives the Load more trigger.
  def has_more?
    load!
    @all.size > @page * PAGE_SIZE
  end

  # remaining — matched lines older than the current page (a floor when
  # truncated?). Sizes the Load more label.
  def remaining
    load!
    [@all.size - (@page * PAGE_SIZE), 0].max
  end

  def truncated?
    load!
    @truncated
  end

  # capped? — more than one page exists (the table can't show it all at
  # once). Distinct from truncated? (the scan itself was bounded).
  def capped?
    matched > PAGE_SIZE
  end

  def elapsed_ms
    load!
    @elapsed_ms
  end

  def empty?
    rows.empty?
  end

  private

  def load!
    return if @loaded

    started   = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    collected = []
    scanned   = 0

    LogTail::Reader.each_line(
      island_id:      island.id,
      pods:           pods.presence,
      from:           from,
      until_:         until_,
      content_search: search.presence,
      regex:          regex?,
      limit:          MATCH_SCAN_CAP
    ) do |pod, hash|
      collected << normalize(pod, hash)
      scanned += 1
    end

    @matched    = scanned
    @truncated  = scanned >= MATCH_SCAN_CAP
    collected.sort_by! { |r| r[:ts] }
    @all        = collected.reverse
    @elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    @loaded     = true
  end

  # window — [from, until] as Time objects, memoised. Custom uses the
  # parsed inputs; presets are relative to now. `from` is clamped to
  # the retention floor so we never walk reaped territory.
  def window
    @window ||= begin
      now = Time.current
      if custom?
        u = parsed_until || now
        # Defensive: custom with a blank `from` (operator cleared it, or
        # the input never captured) defaults to one hour before `until`
        # rather than crashing on a nil comparison below.
        f = parsed_from || (u - 1.hour)
      else
        f = RANGES.fetch(range).ago
        u = now
      end

      floor = RETENTION.ago
      [[f, floor].max, u]
    end
  end

  def parsed_from
    return @parsed_from if defined?(@parsed_from)

    @parsed_from = parse_time(@params[:from])
  end

  def parsed_until
    return @parsed_until if defined?(@parsed_until)

    @parsed_until = parse_time(@params[:until])
  end

  def parse_time(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def normalize(pod, hash)
    {
      ts:     (hash["ts"]     || hash[:ts]).to_s,
      pod:    pod,
      stream: (hash["stream"] || hash[:stream]).to_s,
      level:  (hash["level"]  || hash[:level]),
      msg:    (hash["msg"]    || hash[:msg]).to_s,
      raw:    (hash["raw"]    || hash[:raw]).to_s,
      parsed: truthy?(hash["parsed"] || hash[:parsed])
    }
  end

  def normalize_params(params)
    h = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
    h.symbolize_keys
  rescue StandardError
    {}
  end

  def truthy?(value)
    [true, "true", "1", 1].include?(value)
  end
end
