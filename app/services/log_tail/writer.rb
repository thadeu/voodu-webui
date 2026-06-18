# frozen_string_literal: true

# LogTail::Writer — buffered NDJSON appender for one island.
#
# Lifecycle: open one Writer per LogTailIslandJob run; call
# #append(pod, parsed_hash) for each line; #close on shutdown.
# Internally caches one File handle per (pod, date) and rotates
# at midnight without dropping bytes.
#
# Guard rails:
#
#   - Per-file cap (250MB): once a (pod, date) file hits the cap,
#     the writer stops appending to it, writes one sentinel line
#     `{"_dropped":true,"limit_mb":250,"ts":"…"}` so the export
#     reader can render a banner, and flags the (pod, date) in
#     Rails.cache so the /logs UI can warn.
#
#   - Disk pressure: every N writes, check available disk under
#     storage/. If under 2GB free, stop writes for the rest of the
#     current job invocation (orchestrator will retry next tick;
#     by then the operator presumably freed space or disabled the
#     feature).
#
#   - Per-island disk cap (2GB): NOT enforced inside the hot path
#     (would require expensive du on every line). Enforced by
#     orchestrator before scheduling the island's job.
#
# Concurrency: ONE writer per (island_id, pod) at a time, because
# only one LogTailIslandJob runs per island (TailLock serialises).
# Within an island, pods don't share file handles, so per-pod
# files have no concurrent writers.
module LogTail
  class Writer
    # How often (in line counts) to re-check disk free space.
    # Cheap call but pointless to do every single line.
    DISK_CHECK_EVERY = 1_000

    # Minimum free disk space below which we pause writes.
    MIN_FREE_BYTES = 2 * 1024 * 1024 * 1024  # 2 GB

    # Per-file dedupe window — how many recent line fingerprints we
    # remember. Defensive against the tail job's caller-side dedup
    # ever failing (orchestrator double-spawn, watermark reset on
    # job retry, controller's `--since` being inclusive on the
    # boundary). 5000 lines × ~32 bytes per SHA1 = ~160KB per pod
    # in memory — bounded and cheap. The window is FIFO eviction
    # ordered, so old line hashes drop out as new ones come in.
    #
    # Hash key is (ts + msg) — same tuple that defines "this is
    # the same log line" semantically. Two different events with
    # identical content and millisecond timestamp would collide,
    # but that's vanishingly rare and the cost (losing 1 real line
    # per million) is fine vs the cost of duplicates flooding the
    # warehouse and /logs view.
    DEDUPE_WINDOW_PER_FILE = 5_000

    # On opening a (pod, date) file we seed the dedupe window from the
    # TAIL of what's already on disk, so a fresh Writer (every job run /
    # restart / cache-lost resume) still recognises lines it persisted
    # in a previous run and never re-appends them. Without this seed the
    # window only protected within a single run, so the tail job's
    # cold-start backfill (tail=N, no `since`) re-wrote the overlap on
    # every recycle — the source of the 8–16× duplicate lines observed
    # in the warehouse. Bounded read: we pull at most this many bytes
    # from the end (≈ the recent window; far cheaper than slurping a
    # 50MB day file).
    SEED_FROM_DISK_BYTES = 1 * 1024 * 1024  # 1 MB

    def initialize(island_id)
      @island_id = island_id
      @handles = {}  # { [pod, date_str] => File }
      @sizes = {}  # { [pod, date_str] => Integer (cached size) }
      @seen = {}  # { [pod, date_str] => { hash => true } (insertion-ordered) }
      @write_count = 0
      @disk_ok = true
    end

    # append — write one parsed line to the appropriate (pod, date)
    # NDJSON file. Caller has already passed it through Parser, so
    # `parsed_hash` is the canonical schema.
    #
    # No-ops when the writer is in a paused state (disk pressure
    # OR per-file cap reached for the current bucket).
    def append(pod, parsed_hash)
      return false unless @disk_ok

      pod_name = LogTail::FilePath.safe_pod_name(pod)
      date = today
      key = [pod_name, date]

      # Open the handle FIRST — ensure_handle seeds this bucket's dedupe
      # window from the file tail, so the check below sees lines written
      # by previous runs, not just this one.
      handle, size = ensure_handle(key)
      return false if handle.nil?

      # Skip if we've already written this exact line (this run or a
      # prior one, via the disk-seeded window). Belt-and-suspenders: even
      # if the tail job's watermark dedupe fails (job retry, cold-start
      # backfill, controller --since boundary), we never write the same
      # line twice to disk.
      return false if already_written?(key, parsed_hash)

      line = JSON.generate(parsed_hash) + "\n"
      bytes = line.bytesize

      if size + bytes > LogTail::FilePath::PER_FILE_CAP_BYTES
        drop_and_warn(key, handle)
        return false
      end

      handle.write(line)
      @sizes[key] = size + bytes
      mark_written(key, parsed_hash)

      maybe_check_disk
      true
    end

    # close — flush + close all open handles. Called on job exit.
    def close
      @handles.each_value do |h|
        begin
          h.flush
        rescue
          nil
        end
        begin
          h.close
        rescue
          nil
        end
      end
      @handles.clear
      @sizes.clear
      @seen.clear
    end

    private

    def today
      Date.current.strftime("%Y-%m-%d")
    end

    # already_written? / mark_written — per-(pod,date) sliding
    # window of "lines we've written this session". Hash key is
    # (ts + first 200 chars of msg) — collisions on legitimate
    # distinct events are vanishingly rare; the cost of dropping
    # a real line is much smaller than the cost of duplicates
    # flooding the warehouse (which is what we're seeing now in
    # the existing 339MB tree: up to 8 copies of identical lines).
    #
    # FIFO eviction via Hash insertion order — once the window
    # hits the cap, the oldest hash drops out. Ruby Hash preserves
    # insertion order since 1.9 so `.shift` reliably removes the
    # oldest entry.
    def fingerprint(parsed_hash)
      ts = (parsed_hash[:ts] || parsed_hash["ts"]).to_s
      msg = (parsed_hash[:msg] || parsed_hash["msg"]).to_s
      "#{ts}|#{msg[0, 200]}"
    end

    def already_written?(key, parsed_hash)
      window = @seen[key]
      return false if window.nil?

      window.key?(fingerprint(parsed_hash))
    end

    def mark_written(key, parsed_hash)
      window = (@seen[key] ||= {})
      fp = fingerprint(parsed_hash)

      # Re-insert to refresh recency (LRU-ish), then evict oldest
      # if over capacity.
      window.delete(fp)
      window[fp] = true

      window.shift while window.size > DEDUPE_WINDOW_PER_FILE
    end

    # ensure_handle — returns a [File, current_size] tuple for the
    # given (pod, date) key. Opens lazily, caches, rotates at
    # midnight by purging stale-date entries on first miss.
    def ensure_handle(key)
      cached = @handles[key]
      return [cached, @sizes[key]] if cached

      # Purge any handles for a previous date (this fires once per
      # rotation per pod, when the writer first tries to append to
      # the new day).
      rotate_stale(key.last)

      pod_name, date_str = key
      date_obj = Date.parse(date_str)
      path = LogTail::FilePath.daily_file(@island_id, pod_name, date_obj)

      LogTail::FilePath.ensure_dir(File.dirname(path))

      # 'a' = append, sync via flush after each write (line-buffered).
      file = File.open(path, "a")
      file.sync = true

      # Skip the cap if the file is already past it — set the
      # bucket as "dropped" so we never try to append.
      size = file.size
      if size >= LogTail::FilePath::PER_FILE_CAP_BYTES
        file.close
        return [nil, nil]
      end

      @handles[key] = file
      @sizes[key] = size
      seed_dedupe_from_disk(key, path)
      [file, size]
    end

    # seed_dedupe_from_disk — populate this bucket's dedupe window from
    # the lines already on disk, so a fresh Writer dedupes against prior
    # runs (not just within the current one). Reads only the file's tail
    # (SEED_FROM_DISK_BYTES) since the overlap a re-tail can produce is
    # always among the most recent lines. Runs once per (pod, date) per
    # Writer (ensure_handle returns the cached handle on later appends).
    def seed_dedupe_from_disk(key, path)
      return if @seen.key?(key)

      window = {}
      read_tail_lines(path, DEDUPE_WINDOW_PER_FILE).each do |raw|
        parsed = begin
          JSON.parse(raw)
        rescue JSON::ParserError, EncodingError
          nil
        end
        window[fingerprint(parsed)] = true if parsed.is_a?(Hash)
      end
      @seen[key] = window
    rescue => e
      Rails.logger.warn("log-tail dedupe seed failed island=#{@island_id} #{path}: #{e.class}: #{e.message}")
      @seen[key] ||= {}
    end

    # read_tail_lines — up to `limit` most-recent complete lines from the
    # end of `path`, reading at most SEED_FROM_DISK_BYTES. After a mid-
    # file seek we drop the first (partial) line.
    def read_tail_lines(path, limit)
      size = File.size(path)
      return [] if size.zero?

      File.open(path, "r") do |f|
        if size > SEED_FROM_DISK_BYTES
          f.seek(size - SEED_FROM_DISK_BYTES)
          f.gets
        end
        f.each_line.map(&:chomp).last(limit)
      end
    rescue Errno::ENOENT
      []
    end

    # rotate_stale — close handles whose date != the active date.
    # Called when we see a new date key; ensures yesterday's files
    # get flushed and freed.
    def rotate_stale(active_date)
      @handles.each do |key, handle|
        next if key.last == active_date

        begin
          handle.flush
        rescue
          nil
        end
        begin
          handle.close
        rescue
          nil
        end
        @handles.delete(key)
        @sizes.delete(key)
        @seen.delete(key)  # yesterday's dedupe window is irrelevant today
      end
    end

    # drop_and_warn — file hit the per-file cap. Write one sentinel
    # line, close the handle, flag the (pod, date) in Rails.cache
    # so the UI banner can surface it.
    def drop_and_warn(key, handle)
      pod_name, date_str = key

      sentinel = JSON.generate({
        "_dropped" => true,
        "limit_mb" => LogTail::FilePath::PER_FILE_CAP_BYTES / (1024 * 1024),
        "ts" => Time.current.iso8601(3),
        "msg" => "Daily cap reached — further lines dropped"
      }) + "\n"

      begin
        handle.write(sentinel)
        handle.flush
      rescue
        # already in an error state — proceed to close
      end

      begin
        handle.close
      rescue
        nil
      end
      @handles.delete(key)
      @sizes[key] = LogTail::FilePath::PER_FILE_CAP_BYTES  # mark "full"

      Rails.cache.write(
        cap_flag_key(pod_name, date_str),
        Time.current.iso8601(3),
        expires_in: 25.hours  # > 1 day so the banner shows all day
      )

      Rails.logger.warn(
        "log-tail island=#{@island_id} pod=#{pod_name} date=#{date_str} " \
        "hit daily cap — drops engaged until midnight"
      )
    end

    # cap_flag_key — Rails.cache key the UI reads to render a banner
    # ("Some entries lost today — daily cap reached at HH:MM"). Class
    # method on the writer so the UI side can read with the same key.
    def cap_flag_key(pod_name, date_str)
      self.class.cap_flag_key(@island_id, pod_name, date_str)
    end

    def self.cap_flag_key(island_id, pod_name, date_str)
      "log-tail:cap:#{island_id}:#{pod_name}:#{date_str}"
    end

    # maybe_check_disk — every DISK_CHECK_EVERY writes, statfs the
    # storage volume. Pauses the writer if free space drops below
    # MIN_FREE_BYTES.
    def maybe_check_disk
      @write_count += 1
      return unless (@write_count % DISK_CHECK_EVERY).zero?

      free = disk_free_bytes
      return if free.nil?
      return if free >= MIN_FREE_BYTES

      @disk_ok = false
      Rails.logger.warn(
        "log-tail island=#{@island_id} disk pressure — " \
        "#{(free / 1024.0 / 1024.0).round}MB free, pausing writes"
      )
    end

    # disk_free_bytes — best-effort bytes available. Uses `statvfs`
    # via the standard library when available; nil on unsupported
    # platforms (writer treats nil as "OK, keep writing").
    def disk_free_bytes
      File.stat(LogTail::FilePath.log_root)
      # Ruby stdlib doesn't expose statvfs portably; fall back to
      # `df` parsing for cross-platform reliability.
      out = `df -k #{LogTail::FilePath.log_root.to_s.shellescape} 2>/dev/null`
      return nil unless $?.success?

      # df output: "Filesystem 1024-blocks Used Available Capacity Mounted"
      line = out.lines[1]
      return nil if line.nil?

      cols = line.split
      return nil if cols.length < 4

      cols[3].to_i * 1024  # Available in 1024-blocks → bytes
    rescue
      nil
    end
  end
end
