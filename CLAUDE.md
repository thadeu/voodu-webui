# CLAUDE.md — voodu-webui

Operator dashboard for the [voodu](https://github.com/thadeu/clowk-voodu)
self-hosted PaaS controller. One Rails app, one SQLite volume, talks to
N voodu controllers (called "servers") over their PAT plane.

## Stack at a glance

- **Rails 8.1** on Ruby (see `.ruby-version`)
- **SQLite** + Solid stack: `solid_cache`, `solid_queue`, `solid_cable`
  (4-DB layout — primary / cache / queue / cable — plus a 5th `metrics`
  warehouse DB; see `config/database.yml`)
- **Phlex** for ALL views/components (no ERB). Components inherit
  `Components::Base` (`app/components/base.rb`)
- **Hotwire** (Turbo + Stimulus). esbuild bundles JS, Tailwind 4 bundles CSS
- **pnpm** for JS deps (never npm/yarn — see `package.json` packageManager)
- **Faraday** for HTTP to controllers (`app/services/voodu/client.rb`)
- **PhlexIcons::Hero** aliased as `Icon` (so `Icon::ChartBarOutline.new(...)`)

## Mental model: servers + server routing

Every page hangs off `/<server_key>/...`. Switching servers = swapping
the URL segment. The `server_key` resolves to a `Server` model holding
`endpoint + pat_ciphertext`. Bookmarks and parallel tabs Just Work.

Routes (`config/routes.rb`): `/<server_key>/{overview,pods,logs,metrics,alerts,settings}`
plus management at `/servers` (no server prefix).

The PAT lives encrypted at rest (ActiveRecord Encryption); the WebUI
proxies to `<endpoint>/api/pat/v1/<path>` with `Authorization: Bearer <pat>`.

## Directory layout (the parts you'll actually touch)

```
app/
  components/         # Phlex — UI building blocks
    base.rb           # root class, helpers wired, Icon alias
    ui/               # design-system primitives (Button, Card, Drawer, Modal, ...)
    layouts/          # Dashboard chrome (sidebar + topbar)
    overview/         # stat cards, status pills
    pods/             # list, header, env/labels/network/spec cards
    metrics/          # ChartCard, PodPicker, RangePicker, ReplicaChips
    logs/             # log viewer chrome
  views/              # Phlex page-level views (Index/Show/Frame)
  services/           # PORO data shapers per page
    voodu/client.rb   # the only place that talks to a controller
    *_data.rb         # one per page (OverviewData, MetricsPageData, ...)
    metrics_warehouse.rb # SQL helper around the `metrics` DB
  javascript/
    controllers/      # Stimulus — one file per behavior
  jobs/               # solid_queue (MetricsSync* etc.)
  models/             # ActiveRecord (Server, MetricSample, ...)
config/
  routes.rb           # server-scoped + management routes
  database.yml        # 5-DB layout
  recurring.yml       # solid_queue recurring tasks (metrics sync etc.)
db/
  migrate/            # primary
  metrics_migrate/    # metrics warehouse only
```

## Conventions

### Phlex components
- Always inherit `Components::Base` (gets routes helpers, Icon alias)
- `view_template` is the render method. Use private methods for sub-blocks
  named after what they draw (`def page_head`, `def chart_grid`, etc.)
- Headers explain WHY, not what. Pattern: short purpose + the failure mode
  the design is avoiding
- `render Components::X::Y.new(...)` to compose. NEVER inline duplicates of
  a primitive — extract into `Components::UI::*` first
- **Never use `helpers.X`** — `helpers` is deprecated in phlex-rails 2.4+
  and will be removed. Routes, flash, request, link_to, etc. are already
  exposed directly via the includes in `Components::Base`. Call
  `metrics_path`, `flash`, `request` straight up. Custom controller helpers
  (`form_authenticity_token`, `recent_servers`) are registered there via
  `register_value_helper :name` — add new ones to that list as needed
- **HTML tag name collision**: `header`, `footer`, `section`, `article`,
  `main`, `aside`, `nav`, `figure` are Phlex HTML tag methods. Never name
  a private method these (e.g. `def header` to render the card header).
  Use `card_header`, `panel_footer`, etc. Phlex method_missing resolves
  to your method and breaks the tag rendering

### Tailwind / responsive
- Custom breakpoint prefix: **`vmd:`** (not bare `md:`) — defined in the
  Tailwind config. ALWAYS use it for "tablet+" rules
- **Default `flex flex-col vmd:flex-row`** for any row that holds multiple
  meaningful children. `flex flex-wrap` collapses under `flex-1 min-w-0`
  siblings and triggers `break-all` cascades on mono identifiers
- **Action rows hide labels on mobile**: `span(class: "hidden vmd:inline") { "Label" }`
  on every button when 3+ share a row
- Color tokens are CSS vars: `var(--voodu-accent)`, `var(--voodu-text)`,
  `var(--voodu-text-2)`, `var(--voodu-muted)`, `var(--voodu-muted-2)`,
  `var(--voodu-border)`, `var(--voodu-border-2)`, `var(--voodu-surface)`,
  `var(--voodu-surface-2)`, `var(--voodu-blue)`, `var(--voodu-red)`,
  `var(--voodu-amber)`, `var(--voodu-green)`, `var(--voodu-link)`
  (blue — navigational links). `var(--voodu-accent)` is the **brand-green**
  chrome accent (CTAs, active tab/nav, selected chips, focus) — unified
  with the status green, NOT a chart color. Mirror them via Tailwind
  classes (`text-voodu-muted`, `bg-voodu-surface`, etc.)

### Chart palette (1 metric = 1 color, RED = errors only)

Every chart/sparkline metric has ONE unique color across the site so
operators can glance at a tint and know the signal. `--voodu-red` is
RESERVED for errors / failures / incidents — never use red for a
happy-path metric.

Canonical mapping (assignments live in `MetricsPageData#chart_specs`,
`#ingress_chart_specs`, `PodDetailData#stat_cards`, `OverviewData#stat_*`):

| Metric            | Token              |
|-------------------|--------------------|
| CPU               | `--voodu-purple`   |
| Memory            | `--voodu-blue`     |
| Disk              | `--voodu-teal`     |
| Net Rx            | `--voodu-green`    |
| Net Tx            | `--voodu-indigo`   |
| Block I/O         | `--voodu-cyan`     |
| HTTP Requests     | `--voodu-orange`   |
| HTTP p95 Latency  | `--voodu-amber`    |
| HTTP 5xx Errors   | `--voodu-red`      |
| HTTP Bytes Out    | `--voodu-pink`     |

CPU uses `--voodu-purple` (the old accent hue), kept distinct from the
green chrome accent so charts stay one-color-per-metric.

Adding a new metric? Pick an unused color OR add a new token in
`app/assets/stylesheets/voodu/theme.css` AND register it here.
Never reuse a color for a different signal.

### Services pattern (`*_data.rb`)
- One PORO per page. Controller builds it once, view consumes it
- They own the Voodu::Client calls + memoization + format helpers
- Error/empty cases return defensive shapes (empty arrays, `nil` cards,
  `false` for `*_eligible?`) so views don't need conditionals everywhere

### Stimulus controllers
- One file per behavior under `app/javascript/controllers/`
- Auto-registered via `index.js` import — file name `foo_bar_controller.js`
  becomes `data-controller="foo-bar"`
- Keep them small. If a controller grows past ~150 lines, split the
  feature or move state into the server

### Turbo Frame polling pattern (metrics, logs)
- Full-page Index hosts a `turbo_frame_tag("...", src: current_url)` inside
  a `data-controller="polling"` wrapper with `polling_interval_value`
- A separate `Views::*::Frame` view renders ONLY the frame body
- Controller detects the `Turbo-Frame` header and short-circuits to the
  Frame view (layout: false)
- 30s cadence matches the warehouse sync tick

## Multi-DB: the `metrics` warehouse

`MetricSample` ActiveRecord lives in a dedicated SQLite DB
(`storage/*_metrics.sqlite3`). Schema in `db/metrics_schema.rb`,
migrations in `db/metrics_migrate/`. Rows are written by
`MetricsSyncServerJob` (solid_queue recurring) and read by
`MetricsWarehouse` + `MetricsData` / `MetricsPageData`.

Per-metric aggregation matters: counters (`req_count`, `req_2xx..5xx`,
`bytes_out`) use `SUM`; latencies + peaks (`latency_p50..p99_ms`,
`latency_max_ms`) use `MAX`. See `METRIC_AGGREGATIONS` in
`metrics_warehouse.rb`.

## HTTP ingress eligibility

A pod shows HTTP cards/charts only when `MetricSample.where(source: "ingress", scope:, name:).any?`.
Used by `PodDetailData#ingress_eligible?` (stat cards on pod show) and
`MetricsPageData#ingress_eligible?` (chart grid on /metrics). Both
surfaces gate on the same predicate so they appear/disappear in lockstep.

## Drawer pattern

`Components::UI::Drawer` opens a fetched URL in a right-side panel.
Triggers are anchors (cmd-click still opens full page). Pages that
support drawer-mode (`Views::Pods::Show`, `Views::Logs::Show`) take a
`drawer: true` kwarg and skip the Dashboard chrome.

## Dev workflow

```sh
bin/setup            # one-time: install + db:prepare
bin/dev              # Procfile.dev: rails s + esbuild watch + tailwind watch + bin/jobs
```

Tests: `bin/rails test` (Minitest). System tests under
`test/system/` use Capybara + Cuprite.

Linters: `bin/rubocop` (config in `.rubocop.yml`),
`bin/brakeman` (security).

## When you add or modify UI

Mandatory checklist before declaring "done":

1. **Mobile works at ~360px width**. Resize the browser; don't trust
   the dev viewport. Stack rows, hide labels, keep icons
2. **The new component composes existing `Components::UI::*` primitives**
   instead of duplicating a Button/Card/Modal
3. **Color/spacing uses tokens** (`text-voodu-*`, `bg-voodu-*`,
   `gap-2.5`, `gap-3`, `gap-4` — not arbitrary `gap-[7px]`)
4. **Phlex helpers, not raw `tag.`** unless you genuinely need
   `ActionView::Helpers::TagHelper`

## Where to look first

- Page X is slow → its `*_data.rb` service (N+1 risk, missing memoization)
- A chart looks wrong → `MetricsWarehouse.aggregate_for` + `MetricsData#formatter_for`
- A turbo frame doesn't refresh → check the `Turbo-Frame` header branch
  in the controller
- A drawer opens blank → the embedded page is missing `?embed=1` handling
  in its view
- A polling controller fires too often → `polling_interval_value` on the
  data-controller div

## Agent skills

### Issue tracker

Issues & PRDs live as local markdown under `.scratch/<feature-slug>/` (no
external tracker; PRs are not a triage surface). See `docs/agents/issue-tracker.md`.

### Triage labels

Canonical five roles used verbatim (`needs-triage`, `needs-info`,
`ready-for-agent`, `ready-for-human`, `wontfix`), written as a `Status:`
line in each issue file. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` + `docs/adr/` at the repo root (created
lazily by skills). See `docs/agents/domain.md`.
