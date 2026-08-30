# frozen_string_literal: true

namespace :voodu do
  desc "Delete warehouse rows and log files that belong to no server"
  task purge_orphan_warehouse: :environment do
    # Refuses outside production unless forced, and that guard was written after
    # deleting a developer's local logs with it.
    #
    # LogTail::FilePath::LOG_ROOT is "storage/logs" — NOT scoped by environment.
    # In a container that is harmless, because the volume holds one environment.
    # On a workstation, development and production share the tree, so running
    # this against an empty production database deletes the logs of every
    # development server. The rows are keyed by an id that only means something
    # relative to the database currently connected, which is exactly what makes
    # the mistake silent.
    unless Rails.env.production? || ENV["FORCE"] == "1"
      warn "[warehouse] refusing outside production: storage/logs is shared between " \
           "environments, so this would delete another environment's logs. FORCE=1 to override."
      next
    end

    purged = OrphanWarehousePurge.call

    next if purged.empty?

    warn "[warehouse] purged orphaned telemetry: #{purged.map { |k, v| "#{k}=#{v}" }.join(" ")}"
  end
end
