# frozen_string_literal: true

# LogSurroundingData — the "Surrounding Logs" window for one anchor line
# on /logs/analytics. The operator clicks a result row and gets the lines
# immediately before/after it in its log stream, regardless of the search
# filter that surfaced it.
#
# A "log stream" here is one pod (the controller's per-container fan-out),
# so the default scope is the anchor's pod. `all_pods: true` widens to
# every pod in the window for cross-pod correlation.
#
# `expand` (0, 1, 2…) is the "Load more" level: each step scales BOTH the
# scanned time radius AND the kept context, so the operator can pull in
# more of a long-running process without leaving the modal. `more?` says
# whether another step would reveal anything.
#
# Strategy: scan a time radius (WINDOW × (expand+1)) around the anchor
# with NO content filter, sort chronologically, locate the anchor, then
# keep `before`/`after` lines around it. Time-radius scan keeps a chatty
# pod bounded; SCAN_CAP is the memory backstop.
class LogSurroundingData
  # Base time radius scanned on each side of the anchor (× expand+1).
  WINDOW = 5.minutes

  # Memory backstop on lines pulled in before slicing.
  SCAN_CAP = 10_000

  # Base context kept on each side of the anchor (× expand+1, capped at
  # MAX_CONTEXT). 1000 covers most call/process traces in one shot.
  DEFAULT_CONTEXT = 1_000

  # Hard ceiling on kept context per side, and on the Load more level.
  MAX_CONTEXT = 5_000
  MAX_EXPAND = 4

  attr_reader :island, :pod, :anchor_ts, :expand

  # @param island   [Island]
  # @param pod       [String]  anchor pod
  # @param ts        [String]  anchor timestamp (ISO8601)
  # @param all_pods  [Boolean] widen scope to every pod in the window
  # @param expand    [Integer] Load more level (0 = default window)
  # @param before/after [Integer, nil] explicit context override (tests);
  #        defaults to the expand-scaled context.
  def initialize(island:, pod:, ts:, all_pods: false, expand: 0, before: nil, after: nil)
    @island = island
    @pod = pod.to_s
    @anchor_ts = ts.to_s
    @all_pods = all_pods
    @expand = expand.to_i.clamp(0, MAX_EXPAND)

    ctx = [DEFAULT_CONTEXT * (@expand + 1), MAX_CONTEXT].min
    @before = (before || ctx).to_i.clamp(0, MAX_CONTEXT)
    @after = (after || ctx).to_i.clamp(0, MAX_CONTEXT)
    @window = WINDOW * (@expand + 1)
  end

  def all_pods?
    @all_pods
  end

  def next_expand
    @expand + 1
  end

  # rows — the sliced window, newest → oldest (matches the analytics
  # result list, which sorts ts desc).
  def rows
    load!
    @rows
  end

  # anchor_index — index of the anchor WITHIN #rows, or nil when it
  # couldn't be located (reaped between the search and the drill-in).
  def anchor_index
    load!
    @anchor_index
  end

  def found?
    !anchor_index.nil?
  end

  def empty?
    rows.empty?
  end

  # more? — would another Load more step reveal more lines? True when the
  # current scan cut lines off the slice or hit the scan cap, and we're
  # below the expand ceiling.
  def more?
    load!
    @more
  end

  private

  def load!
    return if @loaded

    anchor = parse_anchor
    if anchor.nil?
      @rows = []
      @anchor_index = nil
      @more = false
      @loaded = true

      return
    end

    scanned = []
    LogTail::Reader.each_line(
      island_id: island.id,
      pods: @all_pods ? nil : [@pod],
      from: anchor - @window,
      until_: anchor + @window,
      content_search: nil,
      regex: false,
      limit: SCAN_CAP
    ) do |pod, hash|
      scanned << normalize(pod, hash)
    end

    scanned.sort_by! { |r| [r[:ts], r[:pod]] }
    idx = locate_anchor(scanned)

    if idx.nil?
      @rows = scanned.first(@before + @after + 1)
      @anchor_index = nil
    else
      lo = [idx - @before, 0].max
      hi = [idx + @after, scanned.size - 1].min
      @rows = scanned[lo..hi] || []
      @anchor_index = idx - lo
    end

    # Present newest-first to match the /logs/analytics result list (which
    # sorts ts desc). The scan + anchor slice above stay chronological —
    # the before/after radius math reads cleanest that way — so we flip the
    # kept window here and remap the anchor into reversed-index space.
    @rows.reverse!
    @anchor_index = (@rows.size - 1) - @anchor_index unless @anchor_index.nil?

    # More to reveal if the slice didn't cover everything scanned, or the
    # scan itself was capped — and we can still grow.
    @more = @expand < MAX_EXPAND && (scanned.size > @rows.size || scanned.size >= SCAN_CAP)
    @loaded = true
  end

  # locate_anchor — exact (ts, pod) match first; fall back to the first
  # line at/after the anchor ts.
  def locate_anchor(rows)
    rows.index { |r| r[:ts] == @anchor_ts && r[:pod] == @pod } ||
      rows.index { |r| r[:ts] >= @anchor_ts }
  end

  def parse_anchor
    return nil if @anchor_ts.blank?

    Time.zone.parse(@anchor_ts)
  rescue ArgumentError, TypeError
    nil
  end

  def normalize(pod, hash)
    {
      ts: (hash["ts"] || hash[:ts]).to_s,
      pod: pod,
      stream: (hash["stream"] || hash[:stream]).to_s,
      level: hash["level"] || hash[:level],
      msg: (hash["msg"] || hash[:msg]).to_s,
      raw: (hash["raw"] || hash[:raw]).to_s,
      parsed: [true, "true", "1", 1].include?(hash["parsed"] || hash[:parsed])
    }
  end
end
