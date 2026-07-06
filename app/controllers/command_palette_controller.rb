# frozen_string_literal: true

# CommandPaletteController — GLOBAL command feed for the ⌘K palette.
#
# Endpoint: GET /command_palette.json
#
# Tenant-LESS by design. The palette is a cross-server surface:
# the operator hits ⌘K anywhere and expects to navigate / restart
# a pod on ANY island, not just the one they're currently viewing.
# So we loop every registered island, build that island's per-island
# command set (Navigate + Pods + Logs + Metrics + Restart), then
# append the global commands (Server switch + Add server + Manage
# servers) once.
#
# Caching:
#
#   - Pod lookups go through `IslandPods.compact`, which has its own
#     30s Rails.cache TTL shared with /pods + /logs + /metrics. So
#     opening the palette right after browsing one of those surfaces
#     is a cache hit per-island.
#
#   - The HTTP response itself sets `Cache-Control: private, max-age=30`
#     so the browser revalidation cadence matches IslandPods.
#
#   - The JS client ALSO caches the JSON in sessionStorage for 30s,
#     so a Cmd-K → ESC → Cmd-K within the window is a pure
#     local-storage read with zero network. This is the "no JSON
#     blob in the page HTML" win the operator asked for: the
#     palette payload only ever travels via XHR, never inlined.
#
# `?org=<short_id>` scopes the feed to the current org's servers (the
# JS reads it off the URL). Required to list anything — the endpoint is
# tenant-less, so it can't infer the org itself; org-less surfaces send
# none and get only the global actions.
#
# `?current=<tenant_key>` lets the JS tell the server which island
# the operator is on RIGHT NOW so the global server-switch list
# can exclude the active one. Optional — when absent, ALL of the org's
# islands appear in the switcher.
class CommandPaletteController < ApplicationController
  skip_before_action :require_tenant!

  def commands
    islands = palette_islands
    current = params[:current].present? ? islands.find { |i| i.key == params[:current] } : nil

    per_island = islands.flat_map do |island|
      pods = IslandPods.compact(safe_client(island), island)
      CommandSet.for(island: island, pods: pods, helpers: helpers)
    end

    globals = CommandSet.globals(
      islands: islands,
      current_island: current,
      helpers: helpers
    )

    response.headers["Cache-Control"] = "private, max-age=30"
    render json: {commands: per_island + globals}
  end

  private

  # palette_islands — the servers the palette can navigate/act on: the CURRENT
  # org's, resolved from `?org=<short_id>` (the JS reads it off the URL). The
  # endpoint is tenant-less, so current_org is nil here — we can't use the
  # org-scoped `all_islands`. Scoping to the passed org keeps the palette inside
  # the same isolation boundary as the sidebar. Org-less surfaces (/islands, /)
  # send no org → only the global actions (add / manage server) show.
  def palette_islands
    org = params[:org].present? ? Org.find_by(short_id: params[:org]) : nil

    org ? org.islands.order(:name).to_a : []
  end

  # safe_client — Voodu::Client construction can raise if the island
  # row is missing endpoint/token. IslandPods.compact tolerates a
  # nil client (returns []), so we collapse construction failures
  # into nil and keep the palette rendering for the OTHER islands.
  def safe_client(island)
    Voodu::Client.new(island)
  rescue => e
    Rails.logger.warn("command_palette: client init failed for #{island.key}: #{e.class} #{e.message}")
    nil
  end
end
