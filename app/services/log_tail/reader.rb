# frozen_string_literal: true

# LogTail::Reader — iterate persisted log lines for an island,
# filtered by [pods, from, until_, content_search]. Yields one
# parsed hash per matching line.
#
# Backs the /logs/analytics search + export (LogSearchData,
# LogSurroundingData, LogsAnalyticsController#export) over the local
# NDJSON warehouse.
#
# Implementation: sequential scan of the relevant per-day files,
# stop-early when `until_` falls inside a file's range. With our
# 250MB/file cap a full-period scan is bounded — 2 days × 250MB
# per pod × N pods worth of read I/O. Sub-5s for typical exports.
#
# No SQL, no index — the file-per-day partitioning IS the index.
module LogTail
  class Reader
    DEFAULT_MATCH_LIMIT = 50_000  # cap matched lines (operator-set)

    # each_line — yields each matched parsed-hash + the pod name.
    # @param island_id [Integer]
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
    def self.each_line(island_id:, pods: nil, from:, until_:,
                       content_search: nil, regex: false,
                       limit: DEFAULT_MATCH_LIMIT, &block)
      new(
        island_id:      island_id,
        pods:           pods,
        from:           from,
        until_:         until_,
        content_search: content_search,
        regex:          regex,
        limit:          limit
      ).each_line(&block)
    end

    def initialize(island_id:, pods:, from:, until_:,
                   content_search:, regex:, limit:)
      @island_id      = island_id
      @from           = from
      @until_         = until_
      @content_search = content_search.to_s
      @matcher        = build_matcher(@content_search, regex)
      @limit          = limit

      # Resolve pod list: explicit list OR every pod with on-disk data.
      requested = Array(pods).compact.reject(&:empty?)
      @pods = if requested.empty?
        LogTail::FilePath.list_pods(island_id)
      else
        requested.map { |p| LogTail::FilePath.safe_pod_name(p) }
      end
    end

    def each_line
      return enum_for(:each_line) unless block_given?

      yielded   = 0
      from_iso  = @from.iso8601(3)
      until_iso = @until_.iso8601(3)

      @pods.each do |pod|
        files = LogTail::FilePath.date_files_in_range(
          @island_id, pod, @from, @until_
        )

        files.each do |path|
          File.foreach(path) do |raw|
            return yielded if yielded >= @limit

            hash = parse_line(raw)
            next if hash.nil?

            # Filter by time first (cheapest discriminant)
            ts = hash[:ts] || hash["ts"]
            next if ts.nil?
            next if ts < from_iso
            next if ts > until_iso

            # Then content filter
            next unless content_match?(hash)

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
        msg:    (hash[:msg]    || hash["msg"]).to_s,
        raw:    (hash[:raw]    || hash["raw"]).to_s,
        level:  (hash[:level]  || hash["level"]).to_s,
        stream: (hash[:stream] || hash["stream"]).to_s
      }

      @matcher.call(record)
    rescue Regexp::TimeoutError
      false
    end
  end
end
