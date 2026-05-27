# frozen_string_literal: true

# LogExportCleanupJob — reaps expired LogExport rows + their on-disk
# files. Runs hourly (see config/recurring.yml).
#
# An export "expires" 24h after `ready_at` (set in LogExportJob).
# `destroy` triggers the `before_destroy :delete_file_from_disk`
# callback on LogExport, so DB + filesystem stay in lockstep.
#
# Also reaps lingering `.partial` files from crashed/timed-out
# jobs — those never make it into a DB row, so we sweep them
# explicitly here.
class LogExportCleanupJob < ApplicationJob
  queue_as :default

  # Orphan .partial threshold: anything older than this is junk
  # from a crashed job. Job timeout is 30s, so 1h is generous.
  PARTIAL_ORPHAN_THRESHOLD = 1.hour

  def perform
    reap_expired_rows
    reap_orphan_partials
  end

  private

  def reap_expired_rows
    count = 0
    LogExport.expired.find_each do |export|
      export.destroy
      count += 1
    end

    Rails.logger.info("log-export cleanup destroyed=#{count} expired rows") if count.positive?
  end

  def reap_orphan_partials
    threshold = PARTIAL_ORPHAN_THRESHOLD.ago
    count     = 0

    Dir.glob(LogTail::FilePath.export_root.join("*.partial")) do |path|
      next if File.mtime(path) >= threshold

      File.delete(path)
      count += 1
    rescue Errno::ENOENT
      # raced with another sweep — fine
    end

    Rails.logger.info("log-export cleanup deleted=#{count} orphan partials") if count.positive?
  end
end
