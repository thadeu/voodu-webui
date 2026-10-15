# frozen_string_literal: true

# FswapiSyncServerJob — one `GET /api/pat/v1/fswapi/overview` for ONE server,
# written as one warehouse sample (source "fswapi"). That row is the aggregated
# history of FreeSWITCH: the page's sparklines and the dashboard count panels
# read it through MetricsWarehouse like any other series.
#
# The lists (calls, channels, registrations, gateways) are NOT stored: they
# are current state, read live when someone looks (DataTable::FswapiSource).
#
# Every poll the plugin answers is recorded, success or not:
#
#   - 200 → fs_up 1 plus the gauges;
#   - 502 (FreeSWITCH down, ESL password refused, the API pod down) → fs_up 0
#     ALONE. The gauges get a gap, not a zero (a zero would read as "no
#     calls"), and the "FreeSWITCH down" alert rule has a series to read.
#
# A WebUI that cannot reach the controller at all (TransportError) records
# nothing: that is "no data" for every alert, not "FreeSWITCH down".
class FswapiSyncServerJob < ApplicationJob
  queue_as :default

  # A PAT without read, or a controller older than v0.18.33 (no fswapi route):
  # neither recovers within the retry budget, and the orchestrator re-enqueues
  # every tick. Discard, with one line so "no data" has a diagnosis.
  discard_on Voodu::Client::AuthError, Voodu::Client::NotFoundError do |job, error|
    Rails.logger.warn("fswapi-sync discarded server=#{job.arguments.first} #{error.class.name.demodulize}: #{error.message}")
  end

  def perform(server_id)
    server = Server.find_by(id: server_id)
    return unless server

    sync(server, Voodu::Client.new(server))
  end

  # sync — the testable core; `client` is injected so tests drive a fake.
  # Returns the inserted row Hash, or nil when the controller was unreachable.
  def sync(server, client, now: Time.current)
    row = begin
      sample_row(server, client.fswapi("overview"), now)
    rescue Voodu::Client::ServerError => e
      Rails.logger.warn("fswapi-sync server=#{server.key} FreeSWITCH down: #{e.message}")

      down_row(server, now)
    end

    MetricSample.bulk_insert([row])

    row
  rescue Voodu::Client::TransportError => e
    Rails.logger.warn("fswapi-sync server=#{server.key} skipped (controller unreachable): #{e.message}")

    nil
  end

  private

  def sample_row(server, overview, now)
    status = overview["status"].is_a?(Hash) ? overview["status"] : {}
    ts = now.utc.iso8601

    payload = {
      source: "fswapi",
      ts: ts,
      up: status["up"] ? true : false,
      fs_up: 1,
      version: status["version"].to_s,
      fs_calls: overview["calls"].to_i,
      fs_channels: overview["channels"].to_i,
      fs_sessions: status["sessions"].to_i,
      fs_sessions_peak: status["sessions_peak"].to_i,
      fs_sessions_per_sec: status["sessions_per_sec"].to_i,
      fs_idle_cpu: status["idle_cpu"].to_f
    }

    {server_id: server.id, source: "fswapi", ts_iso: ts, payload: payload.to_json}
  end

  def down_row(server, now)
    ts = now.utc.iso8601

    {server_id: server.id, source: "fswapi", ts_iso: ts, payload: {source: "fswapi", ts: ts, fs_up: 0}.to_json}
  end
end
