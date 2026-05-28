Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # ActionCable WebSocket endpoint.
  #
  # Required so `turbo_stream_from` subscribers in any view (currently
  # Views::Metrics::Index for live chart updates after MetricsSyncIslandJob
  # broadcasts) can actually establish a WebSocket connection. Without
  # this mount, Rails generates the right
  # `<turbo-cable-stream-source>` HTML but the browser hits 404 on
  # `/cable`, silently never subscribes, and broadcasts fall on the
  # floor — chart stays frozen at pageload time.
  #
  # Rails 8 + turbo-rails doesn't auto-mount cable; the default
  # `config.action_cable.mount_path = "/cable"` only declares WHERE
  # it would be served, not that it IS served. The actual hookup is
  # this routes entry.
  mount ActionCable.server => "/cable"

  # PWA — Rails 8 ships a built-in controller (Rails::PwaController) that
  # serves manifest + service worker from app/views/pwa/*. We use the
  # ERB versions so the SW can interpolate `asset_path(...)` for
  # fingerprinted bundles in production (cache busts when CSS/JS hash
  # changes) and the manifest stays a single source of truth.
  #
  # The .erb extension on app/views/pwa/service-worker.js.erb tells
  # Rails to render it through the asset pipeline; the controller
  # sets the right MIME (application/javascript). Layout adds the
  # `<link rel="manifest">` + a tiny inline registration script.
  get "manifest"        => "rails/pwa#manifest",        as: :pwa_manifest
  get "service-worker"  => "rails/pwa#service_worker",  as: :pwa_service_worker

  # Island registry — operator-facing CRUD lives at the TENANT-LESS
  # root because it's the bootstrapping surface ("I have no islands
  # yet, how do I add one?"). Once an island exists, every other
  # route lives under /:tenant_key/.
  resources :islands, only: [:index, :new, :create, :edit, :update, :destroy]

  # Internal-only API for the out-of-process log poller binary.
  # Deliberately OUTSIDE the `:tenant_key` scope — the binary is
  # global and wants every island in one shot. Auth + loopback/
  # private-IP guards live in the controller itself (see
  # Internal::PollerController).
  namespace :internal do
    get  "poller/islands", to: "poller#islands",             as: :poller_islands
    # Inbound notification from the Go binary that a digest folder
    # has been written. PollerDigestController persists the receipt
    # row + enqueues PollerDigestJob; idempotent on sync_hash.
    post "poller/digest",  to: "poller_digest#create",       as: :poller_digest
  end

  # Bare root — if any islands exist, ApplicationController redirects
  # to /<first-island-key>/; otherwise lands on /islands/new.
  root "dashboard#redirect_to_default"

  get "/styleguide", to: "styleguide#index"

  # ⌘K palette feed — GLOBAL, not tenant-scoped. The JS controller
  # fetches this once per session (with a 30s sessionStorage TTL)
  # and uses it to render commands for every island, not just the
  # one the operator is currently viewing. Lives at the top level
  # because there's no single tenant_key that owns it.
  get "/command_palette.json", to: "command_palette#commands", as: :command_palette

  # Tenant-scoped routes. Every navigation surface (overview, pods,
  # logs, metrics, alerts, settings) hangs off /<key>/ so:
  #
  #   - Switching island is a URL swap, not a server-side session
  #     mutation — bookmarks and cross-tab navigation Just Work.
  #   - Two browser tabs on different islands don't fight over
  #     session[:current_island_id].
  #   - The current island is encoded in the URL itself; no
  #     out-of-band state needed.
  #
  # Container/pod names contain dots ("clowk-web.a3f9"), so we relax
  # the path constraint that would otherwise treat the trailing token
  # as a format extension.
  #
  # Tenant key is exactly 6 base62 chars — matches Island::KEY_*
  # constants. The constraint here prevents the route from
  # accidentally matching /islands/new etc.
  scope ":tenant_key", constraints: { tenant_key: /[a-zA-Z0-9]{6}/ } do
    root "dashboard#index", as: :tenant_root

    get  "/pods",                to: "pods#index",    as: :pods
    get  "/pods/:name",          to: "pods#show",     as: :pod,         constraints: { name: %r{[^/]+} }
    post "/pods/:name/restart",  to: "pods#restart",  as: :restart_pod, constraints: { name: %r{[^/]+} }

    # Logs — multi-source viewer + per-pod viewer + two live stream
    # proxies. `/logs/stream` MUST be registered before `/logs/:name`
    # so the matcher catches the literal first — otherwise `:name`
    # would swallow `stream` and the multi-source endpoint would render
    # the show page (HTML, wrong content-type for a stream subscriber).
    get "/logs",              to: "logs#index",      as: :logs
    get "/logs/stream",       to: "logs#stream_all", as: :logs_stream

    # Warehouse-fed log endpoint: reads from storage/logs/<island_id>/
    # NDJSON files instead of opening a `docker logs -f` SSE through the
    # controller. Accepts ?pod=<name>&since=<iso>. Returns text/plain
    # with `[pod-name] <raw line>\n` per row (compatible with
    # log_stream_controller's existing parser). Client polls this
    # endpoint every ~2s with an advancing `since` watermark.
    #
    # Trade-off vs the SSE endpoints above: ~2s of latency between
    # log emission and visible-in-tab, but ZERO additional `docker
    # logs -f` connections on the controller (the LogTailIslandJob
    # already maintains one per island for the warehouse).
    get "/logs/warehouse_stream", to: "logs#warehouse_stream", as: :logs_warehouse_stream

    # Pods picker drawer body. MUST live BEFORE `/logs/:name` —
    # otherwise the `:name` matcher swallows "pods_picker" and the
    # operator's click on the All pods chip serves the logs viewer
    # (with name=pods_picker) instead of the multi-select drawer.
    # See same ordering note above for /logs/stream.
    get "/logs/pods_picker", to: "logs#pods_picker", as: :pods_picker_logs

    get "/logs/:name",        to: "logs#show",       as: :pod_logs,       constraints: { name: %r{[^/]+} }
    get "/logs/:name/stream", to: "logs#stream",     as: :pod_log_stream, constraints: { name: %r{[^/]+} }

    get  "/metrics",                    to: "metrics#index",            as: :metrics
    get  "/metrics/chart",             to: "metrics#chart",            as: :metrics_chart
    get  "/metrics/display_settings",  to: "metrics#display_settings", as: :metrics_display_settings

    # Log exports — operator-triggered NDJSON dumps from the local
    # log warehouse (storage/logs/). `show` renders the drawer body
    # (Turbo Stream target for status updates); `create` enqueues
    # the LogExportJob; `download` send_files the artifact.
    #
    # Routes intentionally narrow — no index page yet (drawer
    # surfaces "recent exports"; standalone listing is a follow-up).
    # `new` returns the drawer body (form), `create` enqueues the
    # job + responds with turbo_stream that morphs the drawer body
    # into the status block.
    get  "/exports/new",           to: "exports#new",      as: :new_export
    post "/exports",               to: "exports#create",   as: :exports
    get  "/exports/:id",           to: "exports#show",     as: :export,           constraints: { id: /\d+/ }
    get  "/exports/:id/download",  to: "exports#download", as: :download_export,  constraints: { id: /\d+/ }

    get  "/alerts",   to: "alerts#index",   as: :alerts
    get  "/settings", to: "settings#index", as: :settings
    # Settings actions stay under the same tenant scope so the
    # per-server context (current_island) flows through naturally.
    post   "/settings/reconnect",       to: "settings#reconnect",  as: :reconnect_settings
    delete "/settings/pats/:pat_id",    to: "settings#revoke_pat", as: :revoke_pat_settings
    # Operator-global display prefs (timezone today; refresh
    # cadence, theme, etc. later). Singular form post since the
    # endpoint is "save the prefs blob," not REST CRUD.
    post   "/settings/preferences",     to: "settings#update_preferences", as: :update_preferences_settings
  end
end
