# PRD — FreeSWITCH console (voodu-fswapi)

Status: ready-for-agent
Date: 2026-10-14

## Problem

Operators run FreeSWITCH on voodu servers and have no view of it in the
WebUI: how many calls are up now, which gateways are down, who is
registered. The `voodu-fswapi` plugin (v0.1.2) now exposes that data through
the controller's PAT proxy. The WebUI must show it, keep a history of the
counts, and let operators build dashboard panels from it.

## What the plugin gives us

- Installed as the builtin resource `plugins/fswapi`. The WebUI detects it
  with `server.plugin_installed?("fswapi")` (the `/system` sync).
- Reached at `/api/pat/v1/fswapi/<route>` (needs controller ≥ v0.18.33).
- Reads (PAT `read` scope):
  - `/overview` → `{status, calls, channels}` in one ESL connection
  - `/status`, `/calls`, `/calls/count`, `/channels`, `/channels/count`,
    `/registrations`, `/sofia`, `/actions`, `/health`
- Actions (PAT `actions` scope, each OFF until enabled in the plugin):
  `POST /actions/{reloadxml|reloadacl|hupall}`, `POST /calls/{uuid}/kill`.
- Errors: 502 when FreeSWITCH is unreachable or the ESL password is wrong
  (the body names the `vd config:set` fix); 403 for a disabled action.

## Key decision: two kinds of data, two paths

HEP3 is an event stream (every SIP message, append-only), so it is stored.
FreeSWITCH data is mostly **current state**: only the numbers have a history.

| Data | Path | Why |
| --- | --- | --- |
| Counts (`/overview`): active calls, channels, sessions now/peak, sessions/s, idle CPU | polled every 15s → `MetricSample(source: "fswapi")` in the metrics warehouse | the aggregated history: sparklines, charts, later alerts |
| Lists: calls, channels, registrations, gateways | fetched live through the PAT proxy, short cache (~5s per server), never stored | a stored "active calls" table is only stale snapshots |

The overview poll runs whenever the plugin is installed (one request per
server per 15s), not only when a panel exists — the page must open with
history.

## Decisions

- **Separate page `/fswapi`**, not merged into `/hep3`. HEP3 is for
  investigating SIP traffic; FreeSWITCH is for operating the PBX now. Each
  page is gated on its own plugin.
- **Sidebar: a new "Plugins" group (renamed from "Voice" on 2026-10-15: one group for every plugin page — later Postgres, Redis…)** holding HEP3 and FreeSWITCH. HEP3 keeps its
  current icon (`PhoneArrowUpRightOutline`). Each item still shows only when
  its plugin is installed; the group heading hides when both are absent.
- **UI label "FreeSWITCH"** (what the operator recognises); `fswapi` stays the
  plugin/route name.
- **Correlation by link, not by merge:** a live call row gets a "SIP flow"
  action that opens the existing `Hep3::CallFlowModal` by Call-ID, shown only
  when hep3 is also installed.
- **Actions are double-gated in the UI:** the server's PAT has `actions`
  (reuse `ServerPats` — `GET /api/pat/v1/pats` answers 403 for a read-only
  PAT) AND the action is enabled (`GET /actions`). Destructive actions need a
  confirm modal.
- **Palette:** each new chart metric gets its own token in `theme.css` and the
  CLAUDE.md table (1 metric = 1 color). Red only for failures (gateway DOWN,
  ESL unreachable).

## Phases (one issue each)

| # | Issue | Blocked by |
| --- | --- | --- |
| 01 | Overview poller → metrics warehouse | — |
| 02 | Plugins sidebar group + `/fswapi` read-only page | 01 |
| 03 | Dashboard builder: FreeSWITCH panels | 01, 02 |
| 04 | Actions (reloadxml, reloadacl, hupall, kill call) | 02 |
| 05 | HEP3 call-flow link + alerts | 02, 03 |
| 06 | (clowk-voodu, P3) a failed install hook still lists the plugin as installed | — |
| 07 | (local dev, P4) two Solid Queue supervisors run jobs twice | — |
| 08 | (clowk-voodu, P4) flaky pod-exec test in CI | — |

Status 2026-10-15: 01, 02, 03, 06, 07 resolved; 05 partly (alert C left). Next: 04, 05-C, 08.

## Out of scope

- Managing FreeSWITCH instances (the plugin never owns FreeSWITCH).
- More than one FreeSWITCH per server (the plugin has one builtin instance).
- Storing call/channel lists.

## Risks

- **P3** — a wrong ESL password makes every read 502. The page must show the
  plugin's error text (it names the fix), not a generic "unavailable".
- **P3** — older controllers (< v0.18.33) have no `/api/pat/v1/fswapi` route.
  Gate on the plugin being installed; treat 404 as "not available".
- **P4** — the overview poll multiplies by servers. One small request per
  server per 15s; skip servers without the plugin.
