# frozen_string_literal: true

# LogTail::Reader — iterate persisted log lines for an server,
# filtered by [pods, from, until_, content_search]. Yields one
# parsed hash per matching line.
#
# Backs the /logs/analytics search + export (LogSearchData,
# LogSurroundingData, LogsAnalyticsController#export) over the local
# NDJSON warehouse.
#
# Implementation: per-day files, each read from the WINDOW START, not from
# byte zero. A file is append-only and chronological (the writer appends
# lines in the order the container emitted them), so the first line inside
# [from, until] is found by binary search over byte offsets — a handful of
# reads of one line each — and the scan starts there. Before that, a 30
# minute window at the end of a 250 MB day meant reading and JSON-parsing
# the whole day for every pod, and the analytics page opened in seconds
# with "all pods" selected. The scan also stops at the first line past
# `until_`, and lines are date-checked on the raw text before they are
# parsed, so only lines inside the window pay the parse.
#
# The seek backs off SEEK_SLACK_BYTES before the found line: a re-tail can
# append a short overlap slightly out of order, and starting a little early
# costs a few parsed-and-dropped lines while starting late would lose them.
# The exact [from, until] filter still runs on every line, so the seek can
# only ever cost time, never correctness.
#
# No SQL, no index — the file-per-day partitioning plus the seek IS the
# index.
module LogTail
  class Reader
    DEFAULT_MATCH_LIMIT = 50_000  # cap matched lines (operator-set)

    # How far before the first in-window line the scan starts. Bounds the
    # damage from a short out-of-order overlap at a write boundary.
    SEEK_SLACK_BYTES = 256 * 1024

    # A line's timestamp, read off the raw JSON text without parsing it. The
    # writer emits `"ts":"…"` verbatim (JSON.generate of the parser's hash),
    # so the literal match is exact for our own files; anything else falls
    # back to the full parse.
    TS_PATTERN = /"ts":"([^"]*)"/

    # each_line — yields each matched parsed-hash + the pod name.
    # @param server    [Server]
    # @param pods      [Array<String>] empty/nil = all pods on disk
    # @param from      [Time, Date]
    # @param until_    [Time, Date]
    # @param content_search [String, nil] substring filter (or regex)
    # @param regex     [Boolean] interpret content_search as regex
    # @param limit     [Integer] cap on lines yielded
    #
    # @yieldparam pod_name [String]
    # @yieldparam hash     [Hash] parsed line ({ts, pod, level, msg, raw, …})
    # @return [Integer] number of lines yielded
    def self.each_line(server:, from:, until_:, pods: nil,
      content_search: nil, regex: false,
      limit: DEFAULT_MATCH_LIMIT, &block)
      new(
        server: server,
        pods: pods,
        from: from,
        until_: until_,
        content_search: content_search,
        regex: regex,
        limit: limit
      ).each_line(&block)
    end

    def initialize(server:, pods:, from:, until_:,
      content_search:, regex:, limit:)
      # The Server object, not its id: FilePath refuses an id, and holding the
      # object means the caller had to reach it through authorized_servers.
      @server = server
      @from = from
      @until_ = until_
      @content_search = content_search.to_s
      @matcher = build_matcher(@content_search, regex)
      @limit = limit

      # Resolve pod list: explicit list OR every pod with on-disk data.
      requested = Array(pods).compact.reject(&:empty?)
      @pods = if requested.empty?
        LogTail::FilePath.list_pods(server)
      else
        requested.map { |p| LogTail::FilePath.safe_pod_name(p) }
      end
    end

    def each_line
      return enum_for(:each_line) unless block_given?

      yielded = 0
      from_iso = @from.iso8601(3)
      until_iso = @until_.iso8601(3)

      @pods.each do |pod|
        files = LogTail::FilePath.date_files_in_range(
          @server, pod, @from, @until_
        )

        files.each do |path|
          # Bytes read past the window's end. The file is chronological, so
          # the first line past `until_` means the rest is too — except for
          # the same short out-of-order overlap the seek's slack allows for
          # at the start. Reading one slack past the boundary keeps a late
          # line from being cut off, and still ends a 250 MB file a few
          # hundred KB after the window instead of at its last byte.
          overshoot = 0

          each_raw_line_from(path, from_iso) do |raw|
            return yielded if yielded >= @limit

            # Filter by time first, on the raw text, so a line outside the
            # window is skipped without paying for its parse.
            quick_ts = raw[TS_PATTERN, 1]

            if quick_ts
              next if quick_ts < from_iso

              if quick_ts > until_iso
                overshoot += raw.bytesize
                break if overshoot > SEEK_SLACK_BYTES

                next
              end
            end

            hash = parse_line(raw)
            next if hash.nil?

            ts = hash[:ts] || hash["ts"]
            next if ts.nil?
            next if ts < from_iso
            next if ts > until_iso

            # Then content filter
            next unless content_match?(hash)

            # Scrub ANSI colour escapes on the way out so any line captured
            # before the ingestion-side fix (LogTail::Parser) — or by a path
            # that skipped it — still renders/exports clean. No-op on already-
            # clean lines. Only matched lines pay it, not the whole scan.
            hash["msg"] = LogTail::Ansi.strip(hash["msg"]) if hash["msg"]
            hash["raw"] = LogTail::Ansi.strip(hash["raw"]) if hash["raw"]

            # Drop content-less orphan rows — a lone docker timestamp on a blank
            # source line (or a line that was nothing but colour escapes, now
            # scrubbed to empty above). They'd render as a bare timestamp and
            # only litter the table/export. Checked AFTER the ANSI scrub.
            next if LogTail::BlankLine.blank?(hash["msg"], hash["raw"])

            yield(pod, hash)
            yielded += 1
          end
        rescue Errno::ENOENT
          # File reaped mid-scan — fine.
        end
      end

      yielded
    end

    # count_lines — exhaust the iterator without yielding details,
    # for "how many lines does this export contain?" pre-flight.
    def count_lines
      each_line.with_index { |_, _| }.size || 0
    end

    private

    # each_raw_line_from — every line of `path` from the first one that can
    # be inside the window, found by window_start_offset.
    def each_raw_line_from(path, from_iso)
      File.open(path, "r") do |f|
        start = window_start_offset(f, from_iso)
        f.seek(start)
        f.each_line { |raw| yield raw }
      end
    end

    # window_start_offset — the byte offset to start reading from: a little
    # before the first line whose ts is >= from_iso, or 0 when the file is
    # small, unparseable at the probes, or starts inside the window.
    #
    # Binary search over byte offsets. Each probe seeks to the middle, skips
    # to the next line boundary and reads that line's ts off the raw text.
    # A probe that lands on a line with no readable ts (a sentinel, a
    # truncated last line) is treated as "before the window" so the search
    # keeps moving right and the exact filter in each_line settles it.
    def window_start_offset(f, from_iso)
      size = f.size
      return 0 if size <= SEEK_SLACK_BYTES

      lo = 0
      hi = size

      while lo < hi
        mid = (lo + hi) / 2
        offset, ts = probe_line(f, mid)

        # No full line after mid: everything past here is the file's tail,
        # which the linear scan from lo will cover.
        if offset.nil?
          hi = mid
          next
        end

        # An in-window line at or after mid bounds the answer at mid, not at
        # the line's own offset: the line mid landed inside (skipped by the
        # probe) starts before mid and may itself be the first in-window
        # line. Bounding at `offset` also stalls when lo already sits inside
        # that skipped line — the probe keeps finding the same boundary.
        if ts && ts >= from_iso
          hi = mid
        else
          lo = offset + 1
        end
      end

      [hi - SEEK_SLACK_BYTES, 0].max.then { |start| line_start_at(f, start) }
    end

    # probe_line — [offset of the first full line at or after `pos`, its ts].
    # Offset is nil when no line boundary exists after `pos`.
    def probe_line(f, pos)
      f.seek(pos)

      if pos.positive?
        return [nil, nil] if f.gets.nil?
      end

      offset = f.pos
      raw = f.gets
      return [nil, nil] if raw.nil?

      [offset, raw[TS_PATTERN, 1]]
    end

    # line_start_at — `pos` moved forward to the next line boundary, so the
    # scan never starts mid-line (0 is always a boundary).
    def line_start_at(f, pos)
      return 0 if pos <= 0

      f.seek(pos)
      f.gets
      f.pos
    end

    def parse_line(raw)
      JSON.parse(raw)
    rescue JSON::ParserError, EncodingError
      nil
    end

    # build_matcher — returns a Proc(record)->bool, where record is
    # { msg:, raw:, level:, stream: }. Empty search = always-true (cheap pass).
    #
    #   - regex flag set  → the LEGACY single-regex path (whole needle as one
    #     regexp over msg/raw), kept so old `?regex=1&q=…` URLs still resolve.
    #     The analytics UI no longer sets it — the DSL carries `/regex/` inline.
    #   - otherwise        → LogQuery compiles the needle (plain substring OR the
    #     boolean DSL). Plain text stays a literal substring, so `?q=callid`
    #     bookmarks are unchanged.
    def build_matcher(search, use_regex)
      return ->(_rec) { true } if search.empty?

      if use_regex
        re = build_regex(search)
        return ->(_rec) { false } if re.nil?  # invalid regex → match nothing

        ->(rec) { re.match?(rec[:msg]) || re.match?(rec[:raw]) }
      else
        LogQuery.compile(search).predicate
      end
    end

    def build_regex(source)
      Regexp.new(source, Regexp::IGNORECASE, timeout: LogQuery::REGEX_TIMEOUT)
    rescue RegexpError
      nil
    end

    # content_match? — run the compiled matcher against this line's record.
    # @message terms cover msg + raw (structured + plain); @level / @stream
    # read their own fields. A pathological regex tripping its per-match
    # timeout (ReDoS backstop) is treated as a non-match so the scan survives.
    def content_match?(hash)
      return true if @matcher.nil?

      record = {
        msg: (hash[:msg] || hash["msg"]).to_s,
        raw: (hash[:raw] || hash["raw"]).to_s,
        level: (hash[:level] || hash["level"]).to_s,
        stream: (hash[:stream] || hash["stream"]).to_s
      }

      @matcher.call(record)
    rescue Regexp::TimeoutError
      false
    end
  end
end
