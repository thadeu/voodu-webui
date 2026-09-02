# frozen_string_literal: true

require "test_helper"

# Telemetry whose server no longer exists.
#
# The case this was written for: switching the control plane from SQLite to
# Postgres is a deliberate fresh start, but the volume comes along and a
# Postgres sequence restarts at 1 — so the first server registered afterwards
# inherits the first old server's history. Demonstrated before this existed: a
# server named "servidor-web" reading 99.9% CPU that belonged to a database box.
#
# The narrow rule that makes it safe: a server_id matching no server cannot be
# read through any authorized path (ServerScoped), so it is only ever waiting to
# be mistaken for someone else's.
class OrphanWarehousePurgeTest < ActiveSupport::TestCase
  ORPHAN_ID = 987_654

  setup { @alive = servers(:alpha) }

  teardown do
    FileUtils.rm_rf(LogTail::FilePath.log_root.join(ORPHAN_ID.to_s))
    MetricSample.where(server_id: ORPHAN_ID).delete_all
    HepMessage.where(server_id: ORPHAN_ID).delete_all
  end

  def seed_metric(server_id)
    iso = 1.minute.ago.utc.iso8601
    MetricSample.bulk_insert([{server_id: server_id, source: "system", ts_iso: iso,
                               payload: {source: "system", ts: iso, name: "host", cpu_percent: 1.0}.to_json}])
  end

  def seed_hep(server_id)
    HepMessage.bulk_insert([{server_id: server_id, scope: "fsw", name: "hep3-api",
                             payload: {ts: "2026-06-30 10:00:05.000000", call_id: "c", x_cid: "",
                                       method: "INVITE", response_code: 0}.to_json}])
  end

  test "metrics belonging to no server are removed" do
    seed_metric(ORPHAN_ID)
    seed_metric(@alive.id)

    OrphanWarehousePurge.call

    assert_equal 0, MetricSample.where(server_id: ORPHAN_ID).count
    assert_operator MetricSample.where(server_id: @alive.id).count, :>, 0, "a live server keeps its history"
  end

  test "SIP capture belonging to no server is removed" do
    seed_hep(ORPHAN_ID)
    seed_hep(@alive.id)

    OrphanWarehousePurge.call

    assert_equal 0, HepMessage.where(server_id: ORPHAN_ID).count
    assert_operator HepMessage.where(server_id: @alive.id).count, :>, 0
  end

  test "log directories belonging to no server are removed" do
    orphan_dir = LogTail::FilePath.log_root.join(ORPHAN_ID.to_s)
    FileUtils.mkdir_p(orphan_dir.join("web"))
    live_dir = LogTail::FilePath.server_dir(@alive)
    FileUtils.mkdir_p(live_dir)

    OrphanWarehousePurge.call

    assert_not Dir.exist?(orphan_dir), "an unreachable tree is only waiting to be reused"
    assert Dir.exist?(live_dir), "a live server keeps its logs"
  end

  # The sweeper deletes by absence: any directory whose name is not a live
  # server id goes. That rule is right, and it is why the suite must not share a
  # root with a running bin/dev — no id in this database exists in that one, so
  # every run here would delete the developer's logs and this file's
  # "nothing to remove" assertion would depend on what bin/dev wrote a second
  # ago. If this ever fails, the isolation was undone and the suite is eating
  # somebody's data again.
  test "the suite sweeps its own root, not the one bin/dev is filling" do
    assert_not_equal Rails.root.join(LogTail::FilePath::LOG_ROOT).to_s,
      LogTail::FilePath.log_root.to_s
  end

  test "it reports what it removed, and says nothing when there is nothing" do
    assert_empty OrphanWarehousePurge.call

    seed_metric(ORPHAN_ID)

    assert_equal 1, OrphanWarehousePurge.call[:metric_samples]
  end
end
