# frozen_string_literal: true

# CommandSet — assembles the list of commands the ⌘K palette shows.
#
# Two execution modes:
#
#   - Per-island (`CommandSet.for(island:, ...)`): builds Navigate
#     + Pods + Logs/Metrics/Restart for ONE island. Used by the
#     /command_palette.json endpoint, which loops every registered
#     island + concatenates the results.
#
#   - Global tail (`CommandSet.globals(islands:, helpers:)`):
#     builds Server-switch + Global actions (Add server, Manage
#     servers). Independent of any single island. Endpoint appends
#     these once after the per-island loop.
#
# Every href is built with EXPLICIT `tenant_key: island.key` — the
# palette is a multi-server surface, so each command must point at
# the specific island it was generated for (not the current request's
# island via default_url_options).
#
# Subtitle convention: pod-bound commands include the SERVER name
# (e.g. "data · postgres:16 · @debian"). Lets the operator scan
# "where does this pod live" without leaving the palette.
class CommandSet
  LOG_QUERIES = [
    { id: "logs-errors", title: "Filter logs to ERROR-level",  match: "logs errors level warn" },
    { id: "logs-5xx",    title: "Filter logs to HTTP 5xx",     match: "logs 5xx 500 502 504 server errors" },
    { id: "logs-4xx",    title: "Filter logs to HTTP 4xx",     match: "logs 4xx 401 404 client errors" },
    { id: "logs-auth",   title: "Filter logs to /api/v1/auth", match: "logs auth login jwt refresh" },
    { id: "logs-slow",   title: "Show slow queries",           match: "logs slow query database" }
  ].freeze

  # ── public entrypoints ──────────────────────────────────────────

  def self.for(island:, pods: [], helpers:)
    new(island: island, pods: Array(pods), helpers: helpers).build_per_island
  end

  def self.globals(islands:, current_island: nil, helpers:)
    new(island: nil, pods: [], helpers: helpers)
      .build_globals(islands: Array(islands), current_island: current_island)
  end

  def initialize(island:, pods:, helpers:)
    @island = island
    @pods   = pods
    @h      = helpers
  end

  # build_per_island — commands scoped to one specific island.
  # Tagged with `island_key` so the client can filter the default
  # view to the current page's island; search shows all islands.
  def build_per_island
    return [] if @island.nil?

    [
      *navigate_commands,
      *pod_jump_commands,
      *per_pod_log_commands,
      *per_pod_metric_commands,
      *saved_log_queries,
      *restart_commands
    ]
  end

  def build_globals(islands:, current_island:)
    [
      *server_switch_commands(islands, current_island),
      *global_commands
    ]
  end

  private

  # ── Navigate (6 per island) ─────────────────────────────────────

  def navigate_commands
    [
      nav(:tenant_root, "Overview", :Squares2x2Outline,   "home dashboard overview"),
      nav(:pods,        "Pods",     :CubeOutline,         "pods list services replicas"),
      nav(:logs,        "Logs",     :DocumentTextOutline, "logs stdout tail stream live"),
      nav(:metrics,     "Metrics",  :ChartBarOutline,     "metrics charts graphs time range"),
      nav(:alerts,      "Alerts",   :BellOutline,         "alerts firing rules history"),
      nav(:settings,    "Settings", :Cog6ToothOutline,    "settings preferences tokens")
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
      id:         "nav-#{route}-#{@island.key}",
      group:      "Navigate",
      island_key: @island.key,
      title:      "Go to #{label}",
      subtitle:   "@ #{@island.name}",
      icon:       icon.to_s,
      match:      "#{match} #{@island.name}",
      href:       @h.public_send("#{route}_path", tenant_key: @island.key)
    }
  end

  # ── Pods — jump to detail ───────────────────────────────────────

  def pod_jump_commands
    @pods.map do |p|
      {
        id:         "pod:#{@island.key}:#{p['name']}",
        group:      "Pods",
        island_key: @island.key,
        title:      pod_title(p),
        subtitle:   "#{p['scope']} · #{p['image']} · @#{@island.name}",
        match:      "#{pod_match_corpus(p)} #{@island.name}",
        status:     normalised_status(p),
        href:       @h.pod_path(name: p["name"], tenant_key: @island.key)
      }
    end
  end

  # ── Logs — jump per pod ──────────────────────────────────────────

  def per_pod_log_commands
    @pods.map do |p|
      {
        id:         "logs:#{@island.key}:#{p['name']}",
        group:      "Logs",
        island_key: @island.key,
        title:      "Logs for #{pod_title(p)}",
        subtitle:   "live tail · #{p['scope']} · @#{@island.name}",
        icon:       "DocumentTextOutline",
        match:      "logs tail stream #{pod_match_corpus(p)} #{@island.name}",
        href:       @h.pod_logs_path(name: p["name"], tenant_key: @island.key)
      }
    end
  end

  # ── Metrics — jump per pod ───────────────────────────────────────

  def per_pod_metric_commands
    @pods.map do |p|
      {
        id:         "metrics:#{@island.key}:#{p['name']}",
        group:      "Metrics",
        island_key: @island.key,
        title:      "Metrics for #{pod_title(p)}",
        subtitle:   "last 1h · #{p['scope']} · @#{@island.name}",
        icon:       "ChartBarOutline",
        match:      "metrics charts #{pod_match_corpus(p)} #{@island.name}",
        href:       "#{@h.metrics_path(tenant_key: @island.key)}?scope_kind=pod&scope_id=#{CGI.escape(p['name'])}"
      }
    end
  end

  # ── Saved log queries ────────────────────────────────────────────

  def saved_log_queries
    LOG_QUERIES.map do |q|
      {
        id:         "#{q[:id]}-#{@island.key}",
        group:      "Logs",
        island_key: @island.key,
        title:      q[:title],
        subtitle:   "saved query · @#{@island.name}",
        icon:       "DocumentTextOutline",
        match:      "#{q[:match]} #{@island.name}",
        href:       @h.logs_path(tenant_key: @island.key)
      }
    end
  end

  # ── Restart actions (running pods only) ──────────────────────────

  def restart_commands
    @pods.filter_map do |p|
      next unless p["running"] == true

      {
        id:          "restart:#{@island.key}:#{p['name']}",
        group:       "Actions",
        island_key:  @island.key,
        title:       "Restart #{pod_title(p)}",
        subtitle:    "#{p['image']} · #{p['scope']} · @#{@island.name}",
        icon:        "ArrowPathOutline",
        match:       "restart kill cycle bounce #{pod_match_corpus(p)} #{@island.name}",
        destructive: true,
        href:        @h.restart_pod_path(name: p["name"], tenant_key: @island.key),
        method:      "POST",
        confirm:     "Restart #{pod_title(p)} on #{@island.name}?"
      }
    end
  end

  # ── Server switching (global) ────────────────────────────────────

  def server_switch_commands(islands, current_island)
    islands.filter_map do |s|
      next if current_island && s.id == current_island.id

      {
        id:       "server:#{s.id}",
        group:    "Servers",
        title:    "Switch to #{s.name}",
        subtitle: s.host.to_s,
        status:   (s.status || :unknown).to_s,
        match:    "server host switch select #{s.name} #{s.host}",
        href:     @h.tenant_root_path(tenant_key: s.key)
      }
    end
  end

  # ── Globals ──────────────────────────────────────────────────────

  def global_commands
    [
      {
        id:       "act-add-server",
        group:    "Actions",
        title:    "Add new server",
        icon:     "PlusOutline",
        match:    "add new server host connect setup register",
        href:     @h.new_island_path
      },
      {
        id:       "act-manage-servers",
        group:    "Actions",
        title:    "Manage servers",
        icon:     "ServerStackOutline",
        match:    "manage servers list edit remove registry",
        href:     @h.islands_path
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
    p["running"] == true ? "running" : "stopped"
  end
end
