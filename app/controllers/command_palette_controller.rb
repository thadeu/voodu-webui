# frozen_string_literal: true

# CommandPaletteController — GLOBAL command feed for the ⌘K palette.
#
# Endpoint: GET /command_palette.json
#
# Server-LESS by design. The palette is a cross-server surface:
# the operator hits ⌘K anywhere and expects to navigate / restart
# a pod on ANY server, not just the one they're currently viewing.
# So we loop every registered server, build that server's per-server
# command set (Navigate + Pods + Logs + Metrics + Restart), then
# append the global commands (Server switch + Add server + Manage
# servers) once.
#
# Caching:
#
#   - Pod lookups go through `ServerPods.compact`, which has its own
#     30s Rails.cache TTL shared with /pods + /logs + /metrics. So
#     opening the palette right after browsing one of those surfaces
#     is a cache hit per-server.
#
#   - The HTTP response itself sets `Cache-Control: private, max-age=30`
#     so the browser revalidation cadence matches ServerPods.
#
#   - The JS client ALSO caches the JSON in sessionStorage for 30s,
#     so a Cmd-K → ESC → Cmd-K within the window is a pure
#     local-storage read with zero network. This is the "no JSON
#     blob in the page HTML" win the operator asked for: the
#     palette payload only ever travels via XHR, never inlined.
#
# `?org=<short_id>` scopes the feed to the current org's servers (the
# JS reads it off the URL). Required to list anything — the endpoint is
# server-less, so it can't infer the org itself; org-less surfaces send
# none and get only the global actions.
#
# `?current=<server_key>` lets the JS tell the server which server
# the operator is on RIGHT NOW so the global server-switch list
# can exclude the active one. Optional — when absent, ALL of the org's
# servers appear in the switcher.
class CommandPaletteController < ApplicationController
  skip_before_action :require_server!

  def commands
    servers = palette_servers
    current = params[:current].present? ? servers.find { |i| i.key == params[:current] } : nil

    per_server = servers.flat_map do |server|
      pods = ServerPods.compact(safe_client(server), server)
      CommandSet.for(server: server, pods: pods, helpers: helpers)
    end

    globals = CommandSet.globals(
      servers: servers,
      current_server: current,
      helpers: helpers
    )

    response.headers["Cache-Control"] = "private, max-age=30"
    render json: {commands: per_server + globals}
  end

  private

  # palette_servers — the servers the palette can navigate/act on: the CURRENT
  # org's, resolved from `?org=<short_id>` (the JS reads it off the URL). The
  # endpoint is server-less, so current_org is nil here — we can't use the
  # org-scoped `all_servers`. Scoping to the passed org keeps the palette inside
  # the same isolation boundary as the sidebar. Org-less surfaces (/servers, /)
  # send no org → only the global actions (add / manage server) show.
  def palette_servers
    org = params[:org].present? ? Org.find_by(short_id: params[:org]) : nil

    org ? org.servers.order(:name).to_a : []
  end

  # safe_client — Voodu::Client construction can raise if the server
  # row is missing endpoint/token. ServerPods.compact tolerates a
  # nil client (returns []), so we collapse construction failures
  # into nil and keep the palette rendering for the OTHER servers.
  def safe_client(server)
    Voodu::Client.new(server)
  rescue => e
    Rails.logger.warn("command_palette: client init failed for #{server.key}: #{e.class} #{e.message}")
    nil
  end
end
