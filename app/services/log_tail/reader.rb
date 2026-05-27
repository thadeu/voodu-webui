# frozen_string_literal: true

# LogTail::Reader — iterate persisted log lines for an island,
# filtered by [pods, from, until_, content_search]. Yields one
# parsed hash per matching line.
#
# Used by LogExportJob to build the export artifact, and by future
# search features (filter on /logs against the local NDJSON).
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

    # build_matcher — returns a Proc that takes a String and returns
    # true/false. Nil/empty search = always-true matcher (cheap pass).
    def build_matcher(search, use_regex)
      return ->(_str) { true } if search.empty?

      if use_regex
        re = build_regex(search)
        return ->(_str) { false } if re.nil?  # invalid regex → match nothing

        ->(str) { re.match?(str) }
      else
        # Case-insensitive substring — operator's "find this ID"
        # usage doesn't need case sensitivity by default.
        needle = search.downcase
        ->(str) { str.downcase.include?(needle) }
      end
    end

    def build_regex(source)
      Regexp.new(source, Regexp::IGNORECASE)
    rescue RegexpError
      nil
    end

    # content_match? — check the search needle against msg + raw.
    # Both fields covered so the operator can find content whether
    # the log was structured (msg field) or plain (raw field).
    def content_match?(hash)
      return true if @matcher.nil?

      msg = (hash[:msg] || hash["msg"]).to_s
      raw = (hash[:raw] || hash["raw"]).to_s

      @matcher.call(msg) || @matcher.call(raw)
    end
  end
end
