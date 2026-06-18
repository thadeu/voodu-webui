# frozen_string_literal: true

# LogTail::FilePath — single source of truth for log file paths.
#
# Layout:
#
#   storage/logs/<island_id>/<pod_name>/YYYY-MM-DD.ndjson
#
# Partition by (island, pod, date) so that:
#   - Cleanup is `find storage/logs -name "*.ndjson" -mtime +2 -delete`
#   - Export reads only the date files in range, never scans the lot
#   - Multi-tenant isolation: deleting an island removes its tree
#
# Pod names from the controller are already container names like
# `clowk-vd-docs.35a3` — safe filesystem chars (alnum + `-` + `.`).
# We still sanitise defensively in `safe_pod_name` to avoid surprise
# slashes if the controller ever changes naming.
module LogTail
  module FilePath
    module_function

    LOG_ROOT = "storage/logs"

    # Cap per (pod, day) file in bytes. 250MB matches the operator
    # decision — drop+warn behaviour kicks in when a file hits this.
    PER_FILE_CAP_BYTES = 250 * 1024 * 1024

    # Cap total disk under storage/logs/<island_id>/. 2GB matches the
    # operator decision — orchestrator pauses tails for that island
    # when its tree exceeds this.
    PER_ISLAND_CAP_BYTES = 2 * 1024 * 1024 * 1024

    # Retention window: anything with mtime older than this gets
    # reaped by LogTailCleanupJob.
    RETENTION_DAYS = 2

    # Root directory absolute path. Created on demand by the writer.
    def log_root
      Rails.root.join(LOG_ROOT)
    end

    # Per-island directory: storage/logs/<island_id>/
    def island_dir(island_id)
      log_root.join(island_id.to_s)
    end

    # Per-pod directory: storage/logs/<island_id>/<pod>/
    def pod_dir(island_id, pod_name)
      island_dir(island_id).join(safe_pod_name(pod_name))
    end

    # Per-day file: storage/logs/<island_id>/<pod>/YYYY-MM-DD.ndjson
    # `date` is a Date or anything responding to #strftime.
    def daily_file(island_id, pod_name, date)
      pod_dir(island_id, pod_name).join("#{date.strftime("%Y-%m-%d")}.ndjson")
    end

    # ensure_dir — mkdir_p on demand. Writer calls before every open
    # (cheap noop on hot path; idempotent).
    def ensure_dir(path)
      FileUtils.mkdir_p(path)
    end

    # safe_pod_name — defensive sanitiser. Strips path traversal,
    # restricts to [A-Za-z0-9_.-] to keep filesystems happy across
    # macOS/Linux. Returns "_unknown" for empty input.
    def safe_pod_name(raw)
      cleaned = raw.to_s.gsub(/[^A-Za-z0-9_.-]/, "_")
      cleaned.empty? ? "_unknown" : cleaned
    end

    # date_files_in_range — list of daily file paths overlapping the
    # [from, until] window for a pod. Returns existing files only;
    # callers iterate this list to read NDJSON for export.
    def date_files_in_range(island_id, pod_name, from, until_)
      from_date = from.to_date
      until_date = until_.to_date

      (from_date..until_date).filter_map do |date|
        path = daily_file(island_id, pod_name, date)
        path if File.exist?(path)
      end
    end

    # list_pods — discover which pods have stored data for an island.
    # Used by the Reader to handle "All pods" exports without
    # needing the controller's current pod list.
    def list_pods(island_id)
      dir = island_dir(island_id)
      return [] unless Dir.exist?(dir)

      Dir.children(dir).sort
    end

    # island_disk_bytes — total bytes under storage/logs/<island_id>/.
    # Walks the tree once; cheap enough for orchestrator's per-tick
    # check (a few MB-sized files per pod per day).
    def island_disk_bytes(island_id)
      dir = island_dir(island_id)
      return 0 unless Dir.exist?(dir)

      total = 0
      Dir.glob(dir.join("**/*.ndjson")) do |path|
        total += File.size(path)
      rescue Errno::ENOENT
        # file got reaped mid-scan — skip
      end
      total
    end
  end
end
