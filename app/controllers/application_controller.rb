# frozen_string_literal: true

# ApplicationController — root of the controller hierarchy.
#
# The WebUI is multi-server by URL: every navigation route lives
# under `/:server_key/` (see config/routes.rb). The `server_key` is
# Server#key — a stable 6-char base62 string. This means:
#
#   - current_server is resolved from `params[:server_key]` alone,
#     not from a session cookie. Two browser tabs on different
#     servers don't fight each other.
#   - Bookmarks include the server context; pasting a URL into
#     another browser shows the same data.
#   - The "switch server" affordance is just a URL swap.
#
# Server-less routes (the ServersController CRUD + `/` redirect +
# `/styleguide`) opt out via `skip_before_action :require_server!`.
#
# Exposes `current_path` and `current_server` to every subclass so
# the dashboard layout (which highlights the active sidebar item
# + renders the server switcher) can be rendered without each
# controller having to re-derive them.
class ApplicationController < ActionController::Base
  # `return_to_path` — a safe "come back here" target for modals/drawers.
  include Returnable

  # Only allow modern browsers supporting webp images, web push, badges,
  # import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern, with: :webp

  # How many recently-visited servers to keep in the sidebar.
  # 6 is a sweet spot between "useful MRU" and "doesn't dominate the
  # sidebar". The full list is still one click away via the "See all"
  # link the sidebar renders below the LRU window.
  MAX_RECENT_SERVERS = 6

  before_action :require_server!

  # WebTime memoises the operator's configured timezone in a
  # thread-local hash for the duration of one request — keeps every
  # `WebTime.in_zone(...)` call inside one render from re-hitting
  # the Settings table. We must clear it BEFORE each request so a
  # POST that updates the timezone reflects on the redirect, and
  # so threads getting recycled across requests don't carry a
  # stale memo from the previous operator action.
  before_action { WebTime.clear_request_cache }

  # Publish the request's org to Current so WebTime (and anything else that
  # needs org context off the controller) can resolve the per-org timezone
  # without threading the org through every render. Rails resets Current at
  # the end of the request, so there's no cross-request bleed.
  before_action { Current.org = current_org }

  # default_url_options — Rails calls this for EVERY url_for / named
  # route helper. By auto-injecting the current server_key we keep
  # call sites tidy: `metrics_path` Just Works instead of every
  # callsite having to remember `metrics_path(server_key: current_server.key)`.
  #
  # We read `request.path_parameters` (the params that came from the
  # ROUTE itself) instead of `params` (route + query + body), so a
  # stale `?server_key=…` query string doesn't get re-propagated into
  # server-less URLs (e.g. clicking "Edit" on /servers would otherwise
  # generate /servers/:id/edit?server_key=<stale> if the operator
  # arrived with that param in the URL).
  #
  # Routes that pass their own `server_key:` (e.g. the sidebar
  # switcher building a URL for a DIFFERENT server) win — caller's
  # value wins over the default.
  def default_url_options
    path = request.path_parameters
    opts = {}
    opts[:org_id] = path[:org_id] if path[:org_id].present?
    opts[:server_key] = path[:server_key] if path[:server_key].present?
    opts
  end

  private

  # Returns the current request path (e.g. "/a3f9k2/pods").
  # Views forward this to Components::Layouts::Dashboard so the
  # sidebar can mark the right nav item active.
  def current_path
    request.path
  end

  # current_org — the Org from the URL's :org_id segment (its short_id).
  # Memoised; nil on server-less routes. Every server lookup + the sidebar
  # server list scope through this, so the Org is the isolation boundary.
  def current_org
    return @current_org if defined?(@current_org)

    @current_org = params[:org_id].present? ? Org.find_by(short_id: params[:org_id]) : nil
  end

  # all_servers — the servers of the CURRENT ORG, feeding the sidebar list +
  # the recent-server LRU. Scoped to current_org so one org never sees
  # another org's servers. Empty on server-less pages (no org in the URL).
  def all_servers
    @all_servers ||= current_org ? current_org.servers.order(:name).to_a : []
  end

  # all_orgs — every Org, for the topbar org switcher. Small table; a full
  # scan per render is cheap.
  def all_orgs
    @all_orgs ||= Org.order(:name).to_a
  end

  # current_server — the server the operator is currently focused on.
  # Memoised; resolved from `params[:server_key]` once per request.
  # Returns nil only on server-less routes (where require_server!
  # was skipped) — those callers must handle nil themselves.
  #
  # Side effect: stamps the server id at the head of the LRU list so
  # the sidebar's "recent servers" rendering reflects the actual flow
  # the operator just took.
  def current_server
    return @current_server if defined?(@current_server)

    # SCOPED to current_org — a server key only resolves within its own org,
    # so a URL pairing an org with another org's server key 404s (via
    # require_server!) instead of leaking cross-org data.
    @current_server = if params[:server_key].present? && current_org
      current_org.servers.find_by(key: params[:server_key])
    end
    track_recent_server!(@current_server) if @current_server
    @current_server
  end

  # lookup_server — resolve a `?server_id` param to a server WITHIN the current
  # org (the isolation guard), falling back to current_server when it's absent,
  # blank, or points at a forged / cross-org / deleted id. The cross-server read
  # endpoints (datatable / metrics / hep3) use it so a dashboard panel can target
  # ANY server in the org without ever reaching another org's data.
  def lookup_server
    return current_server unless params[:server_id].present? && current_org

    current_org.servers.find_by(id: params[:server_id]) || current_server
  end

  # recent_servers — the LRU-ordered subset of servers surfaced in
  # the sidebar's SERVERS section. Capped at MAX_RECENT_SERVERS so
  # the rail stays short.
  #
  # Semantics:
  #   - Session populated → return those servers in MRU order,
  #     dropping any whose ids no longer exist (deleted servers).
  #   - Session empty (first visit / cleared cookie) → fall back to
  #     the first N alphabetically so the sidebar isn't blank.
  #
  # Stale ids are filtered out instead of bouncing the request —
  # silently degrading is friendlier than a 500 when an operator
  # deletes their last MRU server on another tab.
  def recent_servers
    @recent_servers ||= begin
      ids = Array(session[:recent_server_ids])
      if ids.empty?
        all_servers.first(MAX_RECENT_SERVERS)
      else
        by_id = all_servers.index_by(&:id)
        ids.map { |id| by_id[id] }.compact.first(MAX_RECENT_SERVERS)
      end
    end
  end

  # track_recent_server! — LRU push. Removes any existing occurrence
  # (so re-visiting an server moves it to the head, not duplicates
  # it) and trims to the cap. Mutating session inside a read-path
  # (current_server) is fine here because we only write when the
  # value changes — keeps Rack from forcing a Set-Cookie on every
  # request.
  def track_recent_server!(server)
    ids = Array(session[:recent_server_ids])
    new_ids = ([server.id] + ids.reject { |id| id == server.id }).first(MAX_RECENT_SERVERS)
    session[:recent_server_ids] = new_ids unless new_ids == ids
  end

  # require_server! — gate on every server-scoped controller. If the
  # server_key in the URL doesn't match a registered server (operator
  # bookmarked a URL for an server they later deleted; or typo) we
  # bounce them to /servers so they can pick a real one or register
  # the missing one. We do NOT 404 — the URL shape is operator-supplied
  # and a friendlier landing is more useful than an error page.
  #
  # Subcontrollers that don't live under /:server_key (Servers#*,
  # Dashboard#redirect_to_default, Styleguide) skip this with
  # `skip_before_action :require_server!`.
  def require_server!
    return if current_server

    # A bogus / cross-org server key (or an unknown org) → bounce to the
    # top-level landing, which re-routes to a valid org+server or onboarding.
    # org_id/server_key nil so default_url_options doesn't re-leak the bad
    # segments into the redirect URL.
    alert = params[:server_key].present? ? "Server '#{params[:server_key]}' was not found." : nil
    redirect_to root_path(org_id: nil, server_key: nil), alert: alert
  end

  # drawer_embed? — true when this request was fetched by
  # Components::UI::Drawer to populate its panel body. Set by either:
  #   - `?embed=1` query (used by the canonical href so it's
  #     bookmarkable + reproducible in curl)
  #   - `X-Drawer-Embed: 1` header (set by drawer_controller.js)
  #
  # Controllers gate on this to render with `layout: false` and to
  # pass `drawer: true` into the view so back-links/chrome get
  # suppressed.
  def drawer_embed?
    params[:embed].present? || request.headers["X-Drawer-Embed"].present?
  end

  # voodu_client — Faraday-backed wrapper around the current_server's
  # PAT plane. Controllers that need to hit the controller use this:
  #
  #   voodu_client.pods
  #   voodu_client.restart(pod_name)
  #
  # Returns nil when no server is registered yet — callers should
  # render an empty-state in that case rather than crash.
  def voodu_client
    return nil unless current_server

    @voodu_client ||= Voodu::Client.new(current_server)
  end

  # dashboard_context — the kwargs every Phlex view passes into
  # Components::Layouts::Dashboard.new. Single point of change when
  # the layout needs more context (M5 adds e.g. recent_notifications).
  # NOTE: recent_servers is intentionally NOT in this hash — every
  # View takes explicit kwargs and adding a key here would error
  # ("unknown keyword: :recent_servers") in every View that hasn't
  # opted in. The Sidebar reads `helpers.recent_servers` directly
  # (recent_servers is exposed as a helper_method below).
  def dashboard_context
    {
      current_path: current_path,
      servers: all_servers,
      current_server: current_server
    }
  end

  helper_method :current_path, :all_servers, :recent_servers, :current_server, :current_org, :all_orgs, :voodu_client, :dashboard_context
end
