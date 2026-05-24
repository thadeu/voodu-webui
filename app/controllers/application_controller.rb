# frozen_string_literal: true

# ApplicationController — root of the controller hierarchy.
#
# The WebUI is multi-tenant by URL: every navigation route lives
# under `/:tenant_key/` (see config/routes.rb). The `tenant_key` is
# Island#key — a stable 6-char base62 string. This means:
#
#   - current_island is resolved from `params[:tenant_key]` alone,
#     not from a session cookie. Two browser tabs on different
#     islands don't fight each other.
#   - Bookmarks include the island context; pasting a URL into
#     another browser shows the same data.
#   - The "switch island" affordance is just a URL swap.
#
# Tenant-less routes (the IslandsController CRUD + `/` redirect +
# `/styleguide`) opt out via `skip_before_action :require_tenant!`.
#
# Exposes `current_path` and `current_island` to every subclass so
# the dashboard layout (which highlights the active sidebar item
# + renders the island switcher) can be rendered without each
# controller having to re-derive them.
class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges,
  # import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern, with: :webp

  # How many recently-visited islands to keep in the sidebar.
  # 6 is a sweet spot between "useful MRU" and "doesn't dominate the
  # sidebar". The full list is still one click away via the "See all"
  # link the sidebar renders below the LRU window.
  MAX_RECENT_ISLANDS = 6

  before_action :require_tenant!

  # default_url_options — Rails calls this for EVERY url_for / named
  # route helper. By auto-injecting the current tenant_key we keep
  # call sites tidy: `metrics_path` Just Works instead of every
  # callsite having to remember `metrics_path(tenant_key: current_island.key)`.
  #
  # We read `request.path_parameters` (the params that came from the
  # ROUTE itself) instead of `params` (route + query + body), so a
  # stale `?tenant_key=…` query string doesn't get re-propagated into
  # tenant-less URLs (e.g. clicking "Edit" on /islands would otherwise
  # generate /islands/:id/edit?tenant_key=<stale> if the operator
  # arrived with that param in the URL).
  #
  # Routes that pass their own `tenant_key:` (e.g. the sidebar
  # switcher building a URL for a DIFFERENT island) win — caller's
  # value wins over the default.
  def default_url_options
    key = request.path_parameters[:tenant_key]
    key.present? ? { tenant_key: key } : {}
  end

  private

  # Returns the current request path (e.g. "/a3f9k2/pods").
  # Views forward this to Components::Layouts::Dashboard so the
  # sidebar can mark the right nav item active.
  def current_path
    request.path
  end

  # all_islands — every island the operator has registered. Sorted
  # by name so sidebar order is deterministic. Used by every screen
  # that renders the dashboard layout (the sidebar list).
  def all_islands
    @all_islands ||= Island.order(:name).to_a
  end

  # current_island — the island the operator is currently focused on.
  # Memoised; resolved from `params[:tenant_key]` once per request.
  # Returns nil only on tenant-less routes (where require_tenant!
  # was skipped) — those callers must handle nil themselves.
  #
  # Side effect: stamps the island id at the head of the LRU list so
  # the sidebar's "recent servers" rendering reflects the actual flow
  # the operator just took.
  def current_island
    return @current_island if defined?(@current_island)

    @current_island = params[:tenant_key].present? ? Island.find_by(key: params[:tenant_key]) : nil
    track_recent_island!(@current_island) if @current_island
    @current_island
  end

  # recent_islands — the LRU-ordered subset of islands surfaced in
  # the sidebar's SERVERS section. Capped at MAX_RECENT_ISLANDS so
  # the rail stays short.
  #
  # Semantics:
  #   - Session populated → return those islands in MRU order,
  #     dropping any whose ids no longer exist (deleted islands).
  #   - Session empty (first visit / cleared cookie) → fall back to
  #     the first N alphabetically so the sidebar isn't blank.
  #
  # Stale ids are filtered out instead of bouncing the request —
  # silently degrading is friendlier than a 500 when an operator
  # deletes their last MRU island on another tab.
  def recent_islands
    @recent_islands ||= begin
      ids = Array(session[:recent_island_ids])
      if ids.empty?
        all_islands.first(MAX_RECENT_ISLANDS)
      else
        by_id = all_islands.index_by(&:id)
        ids.map { |id| by_id[id] }.compact.first(MAX_RECENT_ISLANDS)
      end
    end
  end

  # track_recent_island! — LRU push. Removes any existing occurrence
  # (so re-visiting an island moves it to the head, not duplicates
  # it) and trims to the cap. Mutating session inside a read-path
  # (current_island) is fine here because we only write when the
  # value changes — keeps Rack from forcing a Set-Cookie on every
  # request.
  def track_recent_island!(island)
    ids = Array(session[:recent_island_ids])
    new_ids = ([island.id] + ids.reject { |id| id == island.id }).first(MAX_RECENT_ISLANDS)
    session[:recent_island_ids] = new_ids unless new_ids == ids
  end

  # require_tenant! — gate on every tenant-scoped controller. If the
  # tenant_key in the URL doesn't match a registered island (operator
  # bookmarked a URL for an island they later deleted; or typo) we
  # bounce them to /islands so they can pick a real one or register
  # the missing one. We do NOT 404 — the URL shape is operator-supplied
  # and a friendlier landing is more useful than an error page.
  #
  # Subcontrollers that don't live under /:tenant_key (Islands#*,
  # Dashboard#redirect_to_default, Styleguide) skip this with
  # `skip_before_action :require_tenant!`.
  def require_tenant!
    return if current_island

    # Pass `tenant_key: nil` explicitly so default_url_options
    # doesn't leak the bogus key from params back into the redirect
    # URL (otherwise `/zzzzzz/pods` redirects to `/islands?tenant_key=zzzzzz`).
    if params[:tenant_key].present?
      redirect_to islands_path(tenant_key: nil), alert: "Island '#{params[:tenant_key]}' was not found."
    else
      redirect_to root_path(tenant_key: nil)
    end
  end

  # voodu_client — Faraday-backed wrapper around the current_island's
  # PAT plane. Controllers that need to hit the controller use this:
  #
  #   voodu_client.pods
  #   voodu_client.restart(pod_name)
  #
  # Returns nil when no island is registered yet — callers should
  # render an empty-state in that case rather than crash.
  def voodu_client
    return nil unless current_island

    @voodu_client ||= Voodu::Client.new(current_island)
  end

  # dashboard_context — the kwargs every Phlex view passes into
  # Components::Layouts::Dashboard.new. Single point of change when
  # the layout needs more context (M5 adds e.g. recent_notifications).
  # NOTE: recent_islands is intentionally NOT in this hash — every
  # View takes explicit kwargs and adding a key here would error
  # ("unknown keyword: :recent_islands") in every View that hasn't
  # opted in. The Sidebar reads `helpers.recent_islands` directly
  # (recent_islands is exposed as a helper_method below).
  def dashboard_context
    {
      current_path:    current_path,
      islands:         all_islands,
      current_island:  current_island
    }
  end

  helper_method :current_path, :all_islands, :recent_islands, :current_island, :voodu_client, :dashboard_context
end
