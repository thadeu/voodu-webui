# frozen_string_literal: true

require "test_helper"

# Server#uptime is the SINGLE source for the topbar uptime chip on every
# page (overview, metrics, …). These pin: the humanize cascade, the
# boot-time-derived live value, and the staleness guard that stops a
# just-rebooted box from showing the uptime captured before it went down.
class ServerUptimeTest < ActiveSupport::TestCase
  include ActiveSupport::Testing::TimeHelpers

  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @prev_wh = ENV["WAREHOUSE"]
    ENV["WAREHOUSE"] = "1" # ServerState.warehouse? reads ENV each call
  end

  teardown { ENV["WAREHOUSE"] = @prev_wh }

  def attach_system(boot_time:, uptime_seconds:, synced_at:)
    payload = {"host" => {"boot_time" => boot_time, "uptime_seconds" => uptime_seconds}}
    System.create!(server: @server, payload: payload.to_json, synced_at: synced_at)
    @server.reload
  end

  test "humanize_uptime cascades d / h / m / s" do
    assert_equal "45s", Server.humanize_uptime(45)
    assert_equal "5m", Server.humanize_uptime(310)
    assert_equal "1h 1m", Server.humanize_uptime(3_661)
    assert_equal "8h 41m", Server.humanize_uptime(31_260)
    assert_equal "1d 1h", Server.humanize_uptime(90_061)
  end

  test "uptime derives live from boot_time when the snapshot is fresh" do
    travel_to Time.utc(2026, 5, 29, 15, 0, 0) do
      attach_system(
        boot_time: (Time.current - 31_260).iso8601, # 8h41m ago
        uptime_seconds: 999,                             # stale number — must be ignored
        synced_at: Time.current
      )

      assert_equal "8h 41m", @server.uptime
    end
  end

  test "uptime is — when the snapshot is older than the freshness window" do
    attach_system(
      boot_time: 1.hour.ago.iso8601,
      uptime_seconds: 3_600,
      synced_at: 5.minutes.ago # stale → can't trust host stats
    )

    assert_equal "—", @server.uptime
  end

  test "uptime is — when there is no system snapshot" do
    @server.system&.destroy
    @server.reload

    assert_equal "—", @server.uptime
  end

  test "uptime falls back to the snapshot number when boot_time is absent" do
    attach_system(boot_time: "", uptime_seconds: 310, synced_at: Time.current)

    assert_equal "5m", @server.uptime
  end
end
