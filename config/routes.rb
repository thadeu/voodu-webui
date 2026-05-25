Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Island registry — operator-facing CRUD lives at the TENANT-LESS
  # root because it's the bootstrapping surface ("I have no islands
  # yet, how do I add one?"). Once an island exists, every other
  # route lives under /:tenant_key/.
  resources :islands, only: [:index, :new, :create, :edit, :update, :destroy]

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
    get "/logs/:name",        to: "logs#show",       as: :pod_logs,       constraints: { name: %r{[^/]+} }
    get "/logs/:name/stream", to: "logs#stream",     as: :pod_log_stream, constraints: { name: %r{[^/]+} }

    get  "/metrics",        to: "metrics#index",  as: :metrics
    get  "/metrics/chart",  to: "metrics#chart",  as: :metrics_chart
    get  "/alerts",   to: "alerts#index",   as: :alerts
    get  "/settings", to: "settings#index", as: :settings
    # Settings actions stay under the same tenant scope so the
    # per-server context (current_island) flows through naturally.
    post   "/settings/reconnect",       to: "settings#reconnect",  as: :reconnect_settings
    delete "/settings/pats/:pat_id",    to: "settings#revoke_pat", as: :revoke_pat_settings
  end
end
