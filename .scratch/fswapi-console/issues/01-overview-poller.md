# 01 — Overview poller → metrics warehouse

Status: resolved
Blocked by: —

## Goal

Keep the aggregated history of FreeSWITCH: poll `GET /api/pat/v1/fswapi/overview`
every 15s for each server with the plugin, and write one `MetricSample` per
poll.

## Scope

- `Voodu::Client#fswapi_get(route, params = nil)` → `get("fswapi/#{route}")`.
  Map 502 to a typed error that keeps the plugin's message (the ESL password
  hint must reach the UI and the log).
- `FswapiSyncOrchestratorJob` (recurring, 15s, `config/recurring.yml`):
  `Server.find_each`, skip unless `server.plugin_installed?("fswapi")`,
  enqueue `FswapiSyncServerJob(server.id)`.
- `FswapiSyncServerJob`: one `/overview` call → one row
  `{server_id:, source: "fswapi", ts_iso: <poll time, UTC, second precision>,
  payload: {source, ts, calls, channels, sessions, sessions_peak,
  sessions_per_sec, sessions_max, idle_cpu, up}.to_json}`.
  - `discard_on` AuthError / NotFoundError with one warn line (same as
    `Hep3PollerJob`): a controller < v0.18.33 has no route.
  - FreeSWITCH down (502): write nothing, log one warn line with the message.
    A gap in the series is the honest signal.
- `MetricsWarehouse` aggregation: counts and gauges use `MAX` per render
  bucket (`calls`, `channels`, `sessions*`), `idle_cpu` uses `MIN`.

## Prerequisite fix (P3, existing bug)

`MetricSample.last_ts_for(server)` is the Go poller's restart watermark and
reads `MAX(ts_epoch)` across **every** source. Rows that Ruby writes at "now"
(`source: "log"` today, `"fswapi"` next) move it past controller samples the
poller has not pulled yet → a gap after a poller restart. Restrict it to the
sources the poller writes (system / pod / ingress). Add a test that a newer
`log`/`fswapi` row does not move the watermark. Check that the
`idx_metric_samples_watermark` index still serves the query (or add one on
`(server_id, source, ts_epoch)`).

## Acceptance

- With the plugin installed, a row lands every 15s; without it, no request.
- A 502 writes no row and logs the plugin's message.
- Watermark test above passes.
- Tests: job (fake client), client error mapping, watermark.

## Comments

2026-10-15 — Done in voodu-webui d1105d7 (sync jobs, warehouse metrics, watermark fix + index).
