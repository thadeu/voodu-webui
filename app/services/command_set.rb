# frozen_string_literal: true

# CommandSet — assembles the list of commands the ⌘K palette shows.
#
# Two execution modes:
#
#   - Per-server (`CommandSet.for(server:, ...)`): builds Navigate
#     + Pods + Logs/Metrics/Restart for ONE server. Used by the
#     /command_palette.json endpoint, which loops every registered
#     server + concatenates the results.
#
#   - Global tail (`CommandSet.globals(servers:, helpers:)`):
#     builds Server-switch + Global actions (Add server, Manage
#     servers). Independent of any single server. Endpoint appends
#     these once after the per-server loop.
#
# Every href is built with EXPLICIT `org_id: server.org.short_id` +
# `server_key: server.key` (see #loc) — the palette is a server-LESS
# endpoint (no default_url_options injection) and a multi-server surface,
# so each command must fully name the org + server it points at.
#
# Subtitle convention: pod-bound commands include the SERVER name
# (e.g. "data · postgres:16 · @debian"). Lets the operator scan
# "where does this pod live" without leaving the palette.
class CommandSet
  LOG_QUERIES = [
    {id: "logs-errors", title: "Filter logs to ERROR-level", match: "logs errors level warn"},
    {id: "logs-5xx", title: "Filter logs to HTTP 5xx", match: "logs 5xx 500 502 504 server errors"},
    {id: "logs-4xx", title: "Filter logs to HTTP 4xx", match: "logs 4xx 401 404 client errors"},
    {id: "logs-auth", title: "Filter logs to /api/v1/auth", match: "logs auth login jwt refresh"},
    {id: "logs-slow", title: "Show slow queries", match: "logs slow query database"}
  ].freeze

  # ── public entrypoints ──────────────────────────────────────────

  def self.for(server:, helpers:, pods: [])
    new(server: server, pods: Array(pods), helpers: helpers).build_per_server
  end

  def self.globals(servers:, helpers:, current_server: nil)
    new(server: nil, pods: [], helpers: helpers)
      .build_globals(servers: Array(servers), current_server: current_server)
  end

  def initialize(server:, pods:, helpers:)
    @server = server
    @pods = pods
    @h = helpers
  end

  # build_per_server — commands scoped to one specific server.
  # Tagged with `server_key` so the client can filter the default
  # view to the current page's server; search shows all servers.
  def build_per_server
    return [] if @server.nil?

    [
      *navigate_commands,
      *pod_jump_commands,
      *per_pod_log_commands,
      *per_pod_metric_commands,
      *saved_log_queries,
      *restart_commands
    ]
  end

  def build_globals(servers:, current_server:)
    [
      *server_switch_commands(servers, current_server),
      *global_commands
    ]
  end

  private

  # loc — a route's path for `server`, carrying org_id + server_key
  # EXPLICITLY. The palette endpoint is server-less (no org/server in its
  # URL → default_url_options injects nothing) and cross-server (each row
  # targets its own server), so every href must name both. `server.org` is
  # free here — servers come from `org.servers`, so the inverse is preloaded.
  def loc(route, server, **extra)
    @h.public_send("#{route}_path", org_id: server.org.short_id, server_key: server.key, **extra)
  end

  # ── Navigate (6 per server) ─────────────────────────────────────

  def navigate_commands
    [
      nav(:server_root, "Overview", :Squares2x2Outline, "home dashboard overview"),
      nav(:pods, "Pods", :CubeOutline, "pods list services replicas"),
      nav(:logs, "Logs", :DocumentTextOutline, "logs stdout tail stream live"),
      nav(:metrics, "Metrics", :ChartBarOutline, "metrics charts graphs time range"),
      nav(:alerts, "Alerts", :BellOutline, "alerts firing rules history"),
      nav(:settings, "Settings", :Cog6ToothOutline, "settings preferences tokens")
    ]
  end

  # nav — no `shortcut` field. The previous version emitted "G P",
  # "G M", etc. but the palette never wired the matching `G then X`
  # keyboard handler — the chips were decoration claiming a feature
  # that didn't exist. Dropped to keep the row clean and the API
  # honest. Re-add the field + JS handler together if/when the
  # two-key sequence becomes real.
  def nav(route, label, icon, match)
    {
      id: "nav-#{route}-#{@server.key}",
      group: "Navigate",
      server_key: @server.key,
      title: "Go to #{label}",
      subtitle: "@ #{@server.name}",
      icon: icon.to_s,
      match: "#{match} #{@server.name}",
      href: loc(route, @server)
    }
  end

  # ── Pods — jump to detail ───────────────────────────────────────

  def pod_jump_commands
    @pods.map do |p|
      {
        id: "pod:#{@server.key}:#{p["name"]}",
        group: "Pods",
        server_key: @server.key,
        title: pod_title(p),
        subtitle: "#{p["scope"]} · #{p["image"]} · @#{@server.name}",
        match: "#{pod_match_corpus(p)} #{@server.name}",
        status: normalised_status(p),
        href: loc(:pod, @server, name: p["name"])
      }
    end
  end

  # ── Logs — jump per pod ──────────────────────────────────────────

  def per_pod_log_commands
    @pods.map do |p|
      {
        id: "logs:#{@server.key}:#{p["name"]}",
        group: "Logs",
        server_key: @server.key,
        title: "Logs for #{pod_title(p)}",
        subtitle: "live tail · #{p["scope"]} · @#{@server.name}",
        icon: "DocumentTextOutline",
        match: "logs tail stream #{pod_match_corpus(p)} #{@server.name}",
        href: loc(:pod_logs, @server, name: p["name"])
      }
    end
  end

  # ── Metrics — jump per pod ───────────────────────────────────────

  def per_pod_metric_commands
    @pods.map do |p|
      {
        id: "metrics:#{@server.key}:#{p["name"]}",
        group: "Metrics",
        server_key: @server.key,
        title: "Metrics for #{pod_title(p)}",
        subtitle: "last 1h · #{p["scope"]} · @#{@server.name}",
        icon: "ChartBarOutline",
        match: "metrics charts #{pod_match_corpus(p)} #{@server.name}",
        href: "#{loc(:metrics, @server)}?scope_kind=pod&scope_id=#{CGI.escape(p["name"])}"
      }
    end
  end

  # ── Saved log queries ────────────────────────────────────────────

  def saved_log_queries
    LOG_QUERIES.map do |q|
      {
        id: "#{q[:id]}-#{@server.key}",
        group: "Logs",
        server_key: @server.key,
        title: q[:title],
        subtitle: "saved query · @#{@server.name}",
        icon: "DocumentTextOutline",
        match: "#{q[:match]} #{@server.name}",
        href: loc(:logs, @server)
      }
    end
  end

  # ── Restart actions (running pods only) ──────────────────────────

  def restart_commands
    @pods.filter_map do |p|
      next unless p["running"] == true

      {
        id: "restart:#{@server.key}:#{p["name"]}",
        group: "Actions",
        server_key: @server.key,
        title: "Restart #{pod_title(p)}",
        subtitle: "#{p["image"]} · #{p["scope"]} · @#{@server.name}",
        icon: "ArrowPathOutline",
        match: "restart kill cycle bounce #{pod_match_corpus(p)} #{@server.name}",
        destructive: true,
        href: loc(:restart_pod, @server, name: p["name"]),
        method: "POST",
        confirm: "Restart #{pod_title(p)} on #{@server.name}?"
      }
    end
  end

  # ── Server switching (global) ────────────────────────────────────

  def server_switch_commands(servers, current_server)
    servers.filter_map do |s|
      next if current_server && s.id == current_server.id

      {
        id: "server:#{s.id}",
        group: "Servers",
        title: "Switch to #{s.name}",
        subtitle: s.host.to_s,
        status: (s.status || :unknown).to_s,
        match: "server host switch select #{s.name} #{s.host}",
        href: loc(:server_root, s)
      }
    end
  end

  # ── Globals ──────────────────────────────────────────────────────

  def global_commands
    [
      {
        id: "act-add-server",
        group: "Actions",
        title: "Add new server",
        icon: "PlusOutline",
        match: "add new server host connect setup register",
        href: @h.new_server_path
      },
      {
        id: "act-manage-servers",
        group: "Actions",
        title: "Manage servers",
        icon: "ServerStackOutline",
        match: "manage servers list edit remove registry",
        href: @h.servers_path
      }
    ]
  end

  # ── helpers ──────────────────────────────────────────────────────

  def pod_title(p)
    res = p["resource_name"] || p["name"]
    rep = p["replica_id"]
    rep.present? ? "#{res}.#{rep}" : res.to_s
  end

  def pod_match_corpus(p)
    [p["name"], p["scope"], p["resource_name"], p["replica_id"], p["image"], p["kind"]]
      .compact.join(" ")
  end

  def normalised_status(p)
    (p["running"] == true) ? "running" : "stopped"
  end
end
