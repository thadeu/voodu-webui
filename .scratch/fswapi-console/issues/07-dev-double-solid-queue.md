# 07 — Two Solid Queue supervisors in local dev

Status: resolved
Priority: P4
Repo: voodu-webui (local setup)
Blocked by: —

`.env` sets `SOLID_QUEUE_IN_PUMA=1` (the Puma plugin) AND `Procfile.dev` runs
`jobs: bin/jobs`, so every recurring task runs twice per tick in dev
(fswapi_sync writes 2 samples per 15s; hep3_sync and log_metrics_sync double
their work). Keep one: drop `jobs: bin/jobs` from Procfile.dev, or unset
SOLID_QUEUE_IN_PUMA in `.env`. The owner's call — it is their local setup.

## Comments

2026-10-15 — Kept SOLID_QUEUE_IN_PUMA=1; removed `jobs: bin/jobs` from Procfile.dev.
