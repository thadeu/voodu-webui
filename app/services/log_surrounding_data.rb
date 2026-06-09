# frozen_string_literal: true

# LogSurroundingData — the "Surrounding Logs" window for one anchor
# line on /logs/analytics. Mirrors CloudWatch's drill-in: the operator
# clicks a result row and gets the lines immediately before/after it in
# its own log stream, regardless of the search filter that surfaced it.
#
# A "log stream" here is one pod (the controller's per-container fan-
# out), so the default scope is the anchor's pod. `all_pods: true`
# widens to every pod in the window for cross-pod correlation
# ("what else fired around the moment this errored?").
#
# Strategy: scan a tight time radius (WINDOW) around the anchor ts with
# NO content filter, sort chronologically, locate the anchor, then keep
# `before` lines up to it and `after` lines past it. Time-radius rather
# than pure count keeps the scan bounded even for a chatty pod; SCAN_CAP
# is the backstop.
class LogSurroundingData
  # Time radius scanned on each side of the anchor. Generous enough
  # that `before`/`after` line counts are satisfiable for typical
  # traffic without scanning a whole day.
  WINDOW = 5.minutes

  # Backstop on lines pulled into memory before slicing.
  SCAN_CAP = 10_000

  # Default context lines kept on each side of the anchor.
  DEFAULT_CONTEXT = 100

  # Clamp on operator-supplied context so a hand-edited URL can't ask
  # us to keep more than we scan.
  MAX_CONTEXT = 1_000

  attr_reader :island, :pod, :anchor_ts

  # @param island   [Island]
  # @param pod       [String]  anchor pod (the row's pod)
  # @param ts        [String]  anchor timestamp (ISO8601, as rendered
  #                            in the results table)
  # @param before    [Integer] lines to keep before the anchor
  # @param after     [Integer] lines to keep after the anchor
  # @param all_pods  [Boolean] widen scope to every pod in the window
  def initialize(island:, pod:, ts:, before: DEFAULT_CONTEXT, after: DEFAULT_CONTEXT, all_pods: false)
    @island    = island
    @pod       = pod.to_s
    @anchor_ts = ts.to_s
    @before    = before.to_i.clamp(0, MAX_CONTEXT)
    @after     = after.to_i.clamp(0, MAX_CONTEXT)
    @all_pods  = all_pods
  end

  def all_pods?
    @all_pods
  end

  # rows — the sliced window, chronological (oldest → newest), each a
  # plain hash matching LogSearchData#rows shape.
  def rows
    load!
    @rows
  end

  # anchor_index — index of the anchor line WITHIN #rows, or nil when
  # the anchor couldn't be located (e.g. the line was reaped between
  # the search and the drill-in). View highlights this row + scrolls
  # it into view.
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

  private

  def load!
    return if @loaded

    anchor = parse_anchor
    if anchor.nil?
      @rows = []
      @anchor_index = nil
      @loaded = true

      return
    end

    scanned = []
    LogTail::Reader.each_line(
      island_id:      island.id,
      pods:           @all_pods ? nil : [@pod],
      from:           anchor - WINDOW,
      until_:         anchor + WINDOW,
      content_search: nil,
      regex:          false,
      limit:          SCAN_CAP
    ) do |pod, hash|
      scanned << normalize(pod, hash)
    end

    scanned.sort_by! { |r| [r[:ts], r[:pod]] }
    idx = locate_anchor(scanned)

    if idx.nil?
      # Anchor not found — return the centre of the window so the
      # operator still sees the neighbourhood rather than a blank.
      @rows = scanned.first(@before + @after + 1)
      @anchor_index = nil
    else
      lo = [idx - @before, 0].max
      hi = [idx + @after, scanned.size - 1].min
      @rows = scanned[lo..hi] || []
      @anchor_index = idx - lo
    end

    @loaded = true
  end

  # locate_anchor — exact (ts, pod) match first; fall back to the first
  # line at/after the anchor ts so a vanished exact line still anchors
  # roughly the right spot.
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
      ts:     (hash["ts"]     || hash[:ts]).to_s,
      pod:    pod,
      stream: (hash["stream"] || hash[:stream]).to_s,
      level:  (hash["level"]  || hash[:level]),
      msg:    (hash["msg"]    || hash[:msg]).to_s,
      raw:    (hash["raw"]    || hash[:raw]).to_s,
      parsed: [true, "true", "1", 1].include?(hash["parsed"] || hash[:parsed])
    }
  end
end
