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
# `?current=<tenant_key>` lets the JS tell the server which island
# the operator is on RIGHT NOW so the global server-switch list
# can exclude the active one. Optional — when absent, ALL islands
# appear in the switcher.
class CommandPaletteController < ApplicationController
  skip_before_action :require_tenant!

  def commands
    current = lookup_island(params[:current])

    per_island = all_islands.flat_map do |island|
      pods = IslandPods.compact(safe_client(island), island)
      CommandSet.for(island: island, pods: pods, helpers: helpers)
    end

    globals = CommandSet.globals(
      islands: all_islands,
      current_island: current,
      helpers: helpers
    )

    response.headers["Cache-Control"] = "private, max-age=30"
    render json: {commands: per_island + globals}
  end

  private

  def lookup_island(key)
    return nil if key.blank?

    all_islands.find { |i| i.key == key }
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
