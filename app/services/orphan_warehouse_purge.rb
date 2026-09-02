# frozen_string_literal: true

# OrphanWarehousePurge — telemetry whose server no longer exists.
#
# The warehouse lives outside the control plane: metric_samples, hep_messages
# and the NDJSON tree are keyed by a bare integer server_id with no foreign key,
# because they sit in different databases (or on disk). Nothing downstream can
# notice when that id stops meaning what it meant.
#
# Which matters most when the control plane is REPLACED. Switching from SQLite
# to Postgres is a fresh start by design — the operator re-registers their
# servers — but the volume comes along, and a Postgres sequence restarts at 1.
# So the first server registered afterwards inherits the first old server's
# history: a web box showing a database's CPU, silently and convincingly. That
# is not a stale chart, it is the wrong machine's data under the right name.
#
# The rule is narrow enough to be safe anywhere: a server_id that matches no
# server can never be read again through any authorized path (see ServerScoped),
# so it is only ever waiting to be mistaken for someone else.
class OrphanWarehousePurge
  def self.call = new.call

  def call
    live = Server.pluck(:id).to_set

    {
      metric_samples: purge_metrics(live),
      activity_actions: purge_activity(live),
      hep_messages: purge_hep(live),
      log_directories: purge_logs(live)
    }.reject { |_, count| count.zero? }
  end

  private

  def purge_metrics(live)
    orphans = MetricSample.distinct.pluck(:server_id) - live.to_a
    return 0 if orphans.empty?

    MetricSample.where(server_id: orphans).delete_all
  end

  # The action trail of a server nobody can reach any more. Same reasoning as
  # the metrics above: the rows carry a bare server_id and nothing else, so
  # once the Server row is gone there is no surface that could ever show them.
  def purge_activity(live)
    orphans = ActivityAction.distinct.pluck(:server_id) - live.to_a
    return 0 if orphans.empty?

    ActivityAction.where(server_id: orphans).delete_all
  end

  def purge_hep(live)
    orphans = HepMessage.distinct.pluck(:server_id) - live.to_a
    return 0 if orphans.empty?

    HepCursor.where(server_id: orphans).delete_all
    HepMessage.where(server_id: orphans).delete_all
  end

  # The log tree is one directory per server id. Same reasoning, and the same
  # danger: a reused id would serve another machine's logs.
  def purge_logs(live)
    root = LogTail::FilePath.log_root
    return 0 unless Dir.exist?(root)

    Dir.children(root).count do |entry|
      next false unless /\A\d+\z/.match?(entry)
      next false if live.include?(entry.to_i)

      FileUtils.rm_rf(File.join(root, entry))
      true
    end
  end
end
