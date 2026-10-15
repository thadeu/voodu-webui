# 03 — Dashboard builder: FreeSWITCH panels

Status: ready-for-agent
Blocked by: 01, 02

## Goal

Like HEP3, operators can build dashboard panels from FreeSWITCH data.

## Scope

- Builder type card "FreeSWITCH" (shown when any server in the org has the
  plugin), next to the HEP3 card in `type_step_cards`.
- Table panels: `scope_kind: "table"`, `source: "fswapi"`, `view` in
  calls / channels / registrations / gateways. Registered in
  `DataTable::Registry` (`FswapiSource` from issue 02).
- Count panels (number / area / bars / line / gauge_radial / gauge_linear):
  read the warehouse series from issue 01 (`calls`, `channels`,
  `sessions_per_sec`, ...). Decide in the issue whether this is the table
  source's count viz (like hep3) or a metric panel on `source: "fswapi"` —
  pick the one that reuses `MetricsWarehouse` without a live call per render.
- `MetricDashboard` validation: allow `fswapi` where `hep3` is allowed.
- One color per metric (tokens from issue 02).

## Acceptance

- Create, edit, preview and render each panel type; mobile works.
- Tests for `MetricDashboard` validation and the builder form.
