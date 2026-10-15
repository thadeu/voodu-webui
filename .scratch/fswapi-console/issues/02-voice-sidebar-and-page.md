# 02 — Plugins sidebar group + `/fswapi` read-only page

Status: resolved
Blocked by: 01

## Sidebar

- New "Plugins" nav group (was "Voice") (next to Org) with HEP3 and FreeSWITCH. HEP3 moves out
  of `ORG_NAV` and keeps `Icon::PhoneArrowUpRightOutline`.
- FreeSWITCH item: label "FreeSWITCH", `plugin: "fswapi"`, its own icon
  (distinct from HEP3).
- `nav_group` already hides an empty group: no plugin → no "Plugins" heading.
- Collapsed sidebar and mobile work like the other groups.

## Page `/<server_key>/fswapi`

- `FswapiController#index` + `require_fswapi_plugin!` (redirect with an alert,
  same as `Hep3Controller#require_hep3_plugin!`).
- `FswapiPageData` (one PORO, defensive shapes).
- Header: FreeSWITCH version, uptime, idle CPU, up/down pill.
- Stat cards with sparklines from the warehouse (issue 01): active calls,
  channels, sessions/s. Registrations: a plain count from the live list (no
  sparkline — `/overview` does not carry it; add it to the plugin later if
  the history matters).
- Tabs with live tables (Turbo Frame polling, ~10s): Calls, Channels,
  Registrations, Gateways (from `/sofia`; state pill, DOWN = red).
- `DataTable::FswapiSource` (stateless, like `HttpSource`): views `calls`,
  `channels`, `registrations`, `gateways`; `Rails.cache` 5s per
  (server, view) so many viewers make one request.
- Errors: show the plugin's message (502 names the `vd config:set` fix);
  404 → "update the controller to v0.18.33".
- New palette tokens for the new chart metrics in `theme.css` + the CLAUDE.md
  table (red stays for failures only).

## Acceptance

- Mobile at ~360px: cards stack, tables scroll-x or become cards, tab labels
  stay readable.
- No plugin → no sidebar item and the URL redirects.
- System test: page renders with a stubbed client; ESL-down state shows the
  hint.

## Comments

2026-10-15 — Done in voodu-webui d1105d7. Beyond the issue: status tooltips; Channels grouped by
call (header row + A/B legs); transcoding badge; %23 decoded; filter `q` + 100-call cap; live card
headlines. Calls tab has no codec column: `show calls` carries no codec fields.
