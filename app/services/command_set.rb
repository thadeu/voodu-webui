# frozen_string_literal: true

# CommandSet — assembles the list of commands the ⌘K palette
# shows.
#
# Layout choice: server BUILDS the full list per request and dumps
# it as JSON into a data-attribute; the Stimulus controller filters
# / scores / renders client-side. The whole list is ~50–200 items
# (6 nav + N pods × 3 surfaces + N restart + N servers + globals);
# even at 10 pods × 3 servers we're under 100 commands — well
# inside the "send-it-all" budget. No XHR round-trip per keystroke.
#
# Each command is a hash:
#
#   {
#     id:        unique string,
#     group:     "Navigate" | "Pods" | "Logs" | ... ,
#     title:     primary label,
#     subtitle:  optional muted line under the title,
#     match:     extra search corpus (synonyms, IDs, intent words),
#     icon:      Heroicon name (or nil for default dot),
#     status:    pod/server status (renders a StatusDot instead),
#     shortcut:  ["G", "P"] style key list,
#     href:      destination URL,
#     method:    "GET" (default) | "POST" | "DELETE",
#     destructive: true → red selection style + "restart ↵" hint,
#     confirm:   optional message; if set, ask before running
#   }
class CommandSet
  # Saved log queries — curated filter shortcuts. Static for v1;
  # operators can pin their own in a future iteration.
  LOG_QUERIES = [
    { id: "logs-errors", title: "Filter logs to ERROR-level",  match: "logs errors level warn" },
    { id: "logs-5xx",    title: "Filter logs to HTTP 5xx",     match: "logs 5xx 500 502 504 server errors" },
    { id: "logs-4xx",    title: "Filter logs to HTTP 4xx",     match: "logs 4xx 401 404 client errors" },
    { id: "logs-auth",   title: "Filter logs to /api/v1/auth", match: "logs auth login jwt refresh" },
    { id: "logs-slow",   title: "Show slow queries",           match: "logs slow query database" }
  ].freeze

  def self.for(island:, islands: [], pods: [], helpers:)
    new(island: island, islands: Array(islands), pods: Array(pods), helpers: helpers).build
  end

  def initialize(island:, islands:, pods:, helpers:)
    @island  = island
    @islands = islands
    @pods    = pods
    @h       = helpers
  end

  def build
    out = []
    out.concat(navigate_commands) if @island
    out.concat(pod_jump_commands) if @island
    out.concat(per_pod_log_commands) if @island
    out.concat(per_pod_metric_commands) if @island
    out.concat(saved_log_queries) if @island
    out.concat(restart_commands) if @island
    out.concat(server_switch_commands)
    out.concat(global_commands)
    out
  end

  private

  # ── Navigate (6) ─────────────────────────────────────────────────

  def navigate_commands
    [
      nav(:tenant_root, "Overview", :Squares2x2Outline,   %w[G O], "home dashboard overview"),
      nav(:pods,        "Pods",     :CubeOutline,         %w[G P], "pods list services replicas"),
      nav(:logs,        "Logs",     :DocumentTextOutline, %w[G L], "logs stdout tail stream live"),
      nav(:metrics,     "Metrics",  :ChartBarOutline,     %w[G M], "metrics charts graphs time range"),
      nav(:alerts,      "Alerts",   :BellOutline,         %w[G A], "alerts firing rules history"),
      nav(:settings,    "Settings", :Cog6ToothOutline,    %w[G ,], "settings preferences tokens")
    ]
  end

  def nav(route, label, icon, shortcut, match)
    {
      id:       "nav-#{route}",
      group:    "Navigate",
      title:    "Go to #{label}",
      icon:     icon.to_s,
      shortcut: shortcut,
      match:    match,
      href:     @h.public_send("#{route}_path")
    }
  end

  # ── Pods — jump to detail (one per pod) ──────────────────────────

  def pod_jump_commands
    @pods.map do |p|
      {
        id:       "pod:#{p['name']}",
        group:    "Pods",
        title:    pod_title(p),
        subtitle: "#{p['scope']} · #{p['image']}",
        match:    pod_match_corpus(p),
        # Compact /pods uses status=human-string ("Up 2 days"). The
        # JS dot only knows running/restarting/stopped semantics, so
        # we normalise here from the boolean `running` field.
        status:   normalised_status(p),
        href:     @h.pod_path(name: p["name"])
      }
    end
  end

  # ── Logs — jump per pod ──────────────────────────────────────────

  def per_pod_log_commands
    @pods.map do |p|
      {
        id:       "logs:#{p['name']}",
        group:    "Logs",
        title:    "Logs for #{pod_title(p)}",
        subtitle: "live tail · #{p['scope']}",
        icon:     "DocumentTextOutline",
        match:    "logs tail stream #{pod_match_corpus(p)}",
        href:     @h.pod_logs_path(name: p["name"])
      }
    end
  end

  # ── Metrics — jump per pod ───────────────────────────────────────

  def per_pod_metric_commands
    @pods.map do |p|
      {
        id:       "metrics:#{p['name']}",
        group:    "Metrics",
        title:    "Metrics for #{pod_title(p)}",
        subtitle: "last 1h · #{p['scope']}",
        icon:     "ChartBarOutline",
        match:    "metrics charts #{pod_match_corpus(p)}",
        href:     "#{@h.metrics_path}?scope_kind=pod&scope_id=#{CGI.escape(p['name'])}"
      }
    end
  end

  # ── Saved log queries (curated) ──────────────────────────────────

  def saved_log_queries
    LOG_QUERIES.map do |q|
      {
        id:       q[:id],
        group:    "Logs",
        title:    q[:title],
        subtitle: "saved query",
        icon:     "DocumentTextOutline",
        match:    q[:match],
        href:     @h.logs_path
      }
    end
  end

  # ── Restart actions (running pods only) ──────────────────────────
  #
  # Compact /pods returns a human `status` string ("Up 2 days") AND
  # a boolean `running` field. We key off `running == true` so the
  # match is robust to docker's status-string format drift.
  def restart_commands
    @pods.filter_map do |p|
      next unless p["running"] == true

      {
        id:          "restart:#{p['name']}",
        group:       "Actions",
        title:       "Restart #{pod_title(p)}",
        subtitle:    "#{p['image']} · #{p['scope']}",
        icon:        "ArrowPathOutline",
        match:       "restart kill cycle bounce #{pod_match_corpus(p)}",
        destructive: true,
        href:        @h.restart_pod_path(name: p["name"]),
        method:      "POST",
        confirm:     "Restart #{pod_title(p)}?"
      }
    end
  end

  # ── Server switching ─────────────────────────────────────────────

  def server_switch_commands
    @islands.filter_map do |s|
      next if @island && s.id == @island.id

      {
        id:       "server:#{s.id}",
        group:    "Servers",
        title:    "Switch to #{s.name}",
        subtitle: "#{s.host}",
        status:   (s.status || :unknown).to_s,
        match:    "server host switch select #{s.name} #{s.host}",
        href:     @h.tenant_root_path(tenant_key: s.key)
      }
    end
  end

  # ── Globals ──────────────────────────────────────────────────────

  def global_commands
    out = []
    out << {
      id:       "act-add-server",
      group:    "Actions",
      title:    "Add new server",
      icon:     "PlusOutline",
      match:    "add new server host connect setup register",
      href:     @h.new_island_path
    }
    out << {
      id:       "act-manage-servers",
      group:    "Actions",
      title:    "Manage servers",
      icon:     "ServerStackOutline",
      match:    "manage servers list edit remove registry",
      href:     @h.islands_path
    }
    out
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

  # normalised_status — turns the compact response's `running` bool
  # into the semantic state the JS leadingIndicator understands.
  # `status` field is the human "Up 2 days" string, useless for
  # colour mapping.
  def normalised_status(p)
    p["running"] == true ? "running" : "stopped"
  end
end
