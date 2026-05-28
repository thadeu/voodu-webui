# frozen_string_literal: true

# LogTailCleanupJob — deletes NDJSON files older than the retention
# window (2 days, set in LogTail::FilePath::RETENTION_DAYS).
#
# Runs daily at 03:00 (low-traffic hour). Walks storage/logs/ and
# unlinks any *.ndjson whose modification time is older than
# `RETENTION_DAYS` days. Empty pod-directories get removed too so
# we don't leak orphaned tree branches when a pod is decommissioned.
#
# Idempotent + safe to run anytime — if invoked multiple times in
# a row (e.g. operator triggers manually after a disk pressure
# alert), each subsequent run is a no-op.
class LogTailCleanupJob < ApplicationJob
  queue_as :default

  def perform
    # LOG_POLLER_SPAWN=1 — Go binary owns the NDJSON tree, including
    # retention sweeps. Bailing here avoids two cleanup paths
    # racing on the same files (with the binary deleting bytes
    # mid-File.size and this job tripping on Errno::ENOENT noise).
    return if ENV["LOG_POLLER_SPAWN"] == "1"

    root = LogTail::FilePath.log_root
    return unless Dir.exist?(root)

    threshold = LogTail::FilePath::RETENTION_DAYS.days.ago
    deleted   = 0
    bytes     = 0

    Dir.glob(root.join("**/*.ndjson")) do |path|
      mtime = File.mtime(path)
      next if mtime >= threshold

      bytes  += File.size(path)
      File.delete(path)
      deleted += 1
    rescue Errno::ENOENT
      # race with another sweep — fine
    end

    # Remove empty pod-dirs (and empty island-dirs) so the tree
    # doesn't grow forever with decommissioned pod names.
    Dir.glob(root.join("*/*"))
       .select { |d| File.directory?(d) && Dir.empty?(d) }
       .each   { |d| Dir.rmdir(d) rescue nil }
    Dir.glob(root.join("*"))
       .select { |d| File.directory?(d) && Dir.empty?(d) }
       .each   { |d| Dir.rmdir(d) rescue nil }

    Rails.logger.info(
      "log-tail cleanup deleted=#{deleted} files freed=#{(bytes / 1024.0 / 1024.0).round}MB"
    )
  end
end
