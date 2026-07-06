# frozen_string_literal: true

# Views::Settings::Index — per-server settings.
#
# Two cards:
#
#   - Server  → Server record fields the WebUI knows locally
#               (name, key, endpoint, region, infra, registered_at,
#               status). Edit / Remove links point at the existing
#               registry surfaces so we don't duplicate forms.
#
#   - Agent   → /system payload from the agent (kernel, hostname,
#               CPU, memory, uptime). Reconnect button drops the
#               health cache and re-probes.
#
# Global webui prefs (refresh cadence, theme, log buffer cap, …)
# are deliberately OUT — they're not per-server. Those land later
# in a server-LESS /settings/global page.
class Views::Settings::Index < Views::Base
  def initialize(current_path:, servers: [], current_server: nil, system: nil, pats: nil)
    @current_path = current_path
    @servers = servers
    @current_server = current_server
    @system = system
    @pats = pats  # ServerPats::Result or nil
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers, current_server: @current_server,
      breadcrumb: overview_crumbs({label: "Settings"})
    ) do
      if @current_server.nil?
        render Components::UI::NoServerState.new
      else
        body
      end
    end
  end

  private

  def body
    div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
      page_header
      # Layout rhythm:
      #   1. Preferences      (full width — operator-global, sets
      #                        the rendering posture for the rest of
      #                        the page)
      #   2. API tokens       (full width — tabular list, individual
      #                        rows want full reading width)
      #   3. Server + About   (side-by-side grid — both are short
      #                        key/value cards; sitting them in two
      #                        columns at vmd+ kills the wasted
      #                        whitespace they had as stacked
      #                        full-width blocks, and they read as
      #                        the "this server" pair which fits
      #                        their semantic similarity)
      preferences_card
      pat_card
      plugins_card

      div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-4 vmd:gap-5 items-start") do
        server_card
        about_card
      end
    end
  end

  # plugins_card — installed plugins on this server, synced in the
  # /system payload (StateSyncServerJob, 10s). Read-only here; the
  # same list backs feature gates (Server#plugin_installed?) so a
  # plugin-specific UI only appears when its plugin is present.
  def plugins_card
    card = Components::UI::SectionCard.new(title: "Plugins")

    render card do
      list = installed_plugins

      if list.empty?
        p(class: "text-[12px] text-voodu-muted") { "No plugins installed on this server." }
      else
        div { list.each { |pl| plugin_row(pl) } }
      end
    end
  end

  def installed_plugins
    Array(@system&.dig("plugins"))
  end

  # plugin_row — one full-width row per plugin, same chrome as a PAT row:
  # name (bold) + aliases on the left, version on the right.
  def plugin_row(pl)
    name = pl["name"].to_s
    version = pl["version"].to_s
    aliases = Array(pl["aliases"]).map(&:to_s).reject(&:empty?)

    div(class: "grid items-center gap-3 px-3.5 py-2.5 border-b border-voodu-border last:border-b-0",
      style: "grid-template-columns: 1fr auto;") do
      div(class: "min-w-0 flex items-baseline gap-1.5") do
        span(class: "text-[13px] font-semibold text-voodu-text truncate") { name }
        span(class: "text-[11.5px] text-voodu-muted shrink-0") { "(#{aliases.join(", ")})" } if aliases.any?
      end

      span(class: "font-voodu-mono text-[12px] text-voodu-text-2") { version.empty? ? "—" : "v#{version}" }
    end
  end

  # preferences_card — operator-global display prefs. Today: timezone
  # only. Saved via POST /settings/preferences which routes through
  # SettingsController#update_preferences. Persists to the Setting
  # table; every server-rendered timestamp (chart axes, About card
  # boot time, sync chips) reads this value through WebTime.
  #
  # Sits ABOVE the per-server cards because it's a global pref —
  # operators shouldn't have to scroll past per-server stuff to
  # adjust app-wide rendering.
  def preferences_card
    current_tz = WebTime.zone_name

    div(class: "bg-voodu-surface border border-voodu-border") do
      div(class: "px-4 py-3 border-b border-voodu-border flex items-center gap-2") do
        h2(class: "text-[13px] font-semibold text-voodu-text") { "Display preferences" }
        span(class: "text-[11.5px] text-voodu-muted-2") { "applies globally to every server" }
      end

      form(action: update_preferences_settings_path, method: "post", class: "px-4 py-4 flex flex-col gap-3") do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)

        div(class: "flex flex-col gap-1.5") do
          label(for: "settings-timezone", class: "text-[11px] font-semibold uppercase tracking-[0.05em] text-voodu-muted-2") do
            "Timezone"
          end
          input(
            type: "text",
            id: "settings-timezone",
            name: "timezone",
            value: (current_tz == "UTC") ? "" : current_tz,
            placeholder: "America/Sao_Paulo",
            spellcheck: "false",
            autocomplete: "off",
            class: "px-3 h-9 bg-voodu-bg-2 border border-voodu-border text-voodu-text text-[12.5px] font-voodu-mono placeholder:text-voodu-muted-2 focus:outline-none focus:border-voodu-accent-line"
          )
          span(class: "text-[11.5px] text-voodu-muted-2") do
            plain "IANA name (e.g. "
            span(class: "font-voodu-mono") { "America/Sao_Paulo" }
            plain ", "
            span(class: "font-voodu-mono") { "Europe/Lisbon" }
            plain ", "
            span(class: "font-voodu-mono") { "UTC" }
            plain "). Leave blank to use UTC. Current: "
            span(class: "font-voodu-mono text-voodu-text-2") { current_tz }
            plain "."
          end
        end

        div(class: "flex items-center justify-end gap-2") do
          button(
            type: "submit",
            class: "inline-flex items-center px-3 h-8 border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 text-[12px] font-medium hover:bg-voodu-accent hover:text-voodu-on-accent"
          ) { "Save preferences" }
        end
      end
    end
  end

  def page_header
    render(
      Components::UI::PageHeader.new(title: "Settings")
        .with_subtitle { subtitle }
        .with_actions { header_actions }
    )
  end

  def subtitle
    div(class: "flex flex-wrap items-center gap-2.5 mt-1 text-[12.5px] text-voodu-muted") do
      span do
        plain "connected to "
        span(class: "font-voodu-mono text-voodu-text-2") { @current_server.name }
      end

      if (v = controller_version)
        dot_sep
        span do
          plain "voodu "
          span(class: "font-voodu-mono text-voodu-text-2") { "v#{v}" }
        end
      end

      dot_sep
      span(class: "inline-flex items-center gap-1.5") do
        render Components::UI::StatusDot.new(status: @current_server.status || :stopped)
        span { status_label }
      end
    end
  end

  # controller_version — surfaced by handleSystem (see /system's
  # `voodu.version`). Older agents that haven't been upgraded yet
  # don't ship this field — fall back to nil so the chip just
  # collapses (no "voodu v—" placeholder).
  def controller_version
    v = @system&.dig("voodu", "version")
    v.presence
  end

  def status_label
    case @current_server.status
    when :online then "agent online"
    when :offline then "agent offline"
    else "agent status unknown"
    end
  end

  # header_actions — Edit + Remove. Both used to live ALSO inside
  # the Server card's "Actions" row; that row is gone now (the user
  # complained about the duplication). Header is the single
  # affordance for both.
  def header_actions
    a(
      href: edit_server_path(@current_server, return_to: settings_path),
      class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) do
      render Icon::PencilSquareOutline.new(class: "w-3.5 h-3.5")
      span { "Edit server" }
    end
    header_remove_form
  end

  def header_remove_form
    render(Components::UI::Confirmable.new(
      title: "Remove server",
      message: %(Permanently remove "#{@current_server.name}" from the registry? You can re-add it later.),
      confirm_label: "Remove",
      danger: true,
      icon: :TrashOutline,
      form: {
        action: server_path(@current_server),
        method: :delete
      },
      trigger: {
        title: "Remove server",
        "aria-label": "Remove #{@current_server.name}",
        class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-red/30 text-voodu-red text-[12.5px] font-medium hover:bg-voodu-red-dim"
      }
    )) do
      render Icon::TrashOutline.new(class: "w-3.5 h-3.5")
      span { "Remove server" }
    end
  end

  # ── Server card ──────────────────────────────────────────────────

  def server_card
    render(Components::UI::SectionCard.new(title: "Server")) do
      div do
        render(Components::UI::KvRow.new(key: "Name", copy: true, copy_value: @current_server.name)) { plain @current_server.name }
        render(Components::UI::KvRow.new(key: "Key", copy: true, copy_value: @current_server.key)) { plain @current_server.key }
        render(Components::UI::KvRow.new(key: "Endpoint", copy: true, copy_value: @current_server.endpoint)) { plain @current_server.endpoint }
        render(Components::UI::KvRow.new(key: "Region")) { meta_value(@current_server.region) }
        render(Components::UI::KvRow.new(key: "Infra")) { meta_value(@current_server.infra) }
        render(Components::UI::KvRow.new(key: "Registered")) { registered_value }
        render(Components::UI::KvRow.new(key: "Status")) { status_value }
      end
    end
  end

  def meta_value(v)
    if v.blank? || v == "—"
      span(class: "text-voodu-muted-2") { "—" }
    else
      plain v
    end
  end

  def registered_value
    age_secs = (Time.current - @current_server.created_at).to_i
    span do
      plain WebTime.strftime(@current_server.created_at, "%Y-%m-%d %H:%M")
      span(class: "text-voodu-muted ml-2") { "· #{age_label(age_secs)} ago" }
    end
  end

  def status_value
    span(class: "inline-flex items-center gap-2 flex-wrap") do
      render Components::UI::StatusPill.new(status: @current_server.status || :stopped)
      if @current_server.status == :offline
        span(class: "text-voodu-muted text-[11.5px]") do
          plain "Try Reconnect below."
        end
      end
    end
  end

  # ── PAT card ─────────────────────────────────────────────────────

  def pat_card
    return if @pats.nil?

    title = pat_card_title
    card = Components::UI::SectionCard.new(title: title)

    render card do
      if @pats.forbidden?
        pat_forbidden_hint
      elsif @pats.error?
        pat_error_hint(@pats.error)
      elsif @pats.pats.to_a.empty?
        pat_empty_hint
      else
        div { @pats.pats.each { |p| pat_row(p) } }
      end
    end
  end

  def pat_card_title
    if @pats.ok? && @pats.pats.is_a?(Array)
      "API tokens · #{@pats.pats.size}"
    else
      "API tokens"
    end
  end

  # pat_row — one PAT entry. Columns use FIXED widths (not fr) so
  # row-to-row alignment is consistent. Per-row grid containers
  # used to drift visually because `1fr` distributed leftover
  # space differently each time depending on content length.
  # Inspiration uses the same fixed-width strategy.
  #
  # Layout: name (bold) · prefix•••suffix (mono) · scopes badge ·
  # last_used (relative) · Revoke.
  def pat_row(p)
    div(class: "grid items-center gap-3 px-3.5 py-2.5 border-b border-voodu-border last:border-b-0",
      style: "grid-template-columns: 180px 1fr 140px 100px auto;") do
      pat_name(p)
      pat_redacted(p)
      pat_scopes(p)
      pat_last_used(p)
      pat_revoke_form(p)
    end
  end

  def pat_name(p)
    name = p["name"].to_s.presence || "(unnamed)"
    div(class: "min-w-0") do
      span(class: "text-[13px] font-semibold text-voodu-text truncate block") { name }
    end
  end

  def pat_redacted(p)
    prefix = p["prefix"].to_s
    suffix = p["suffix"].to_s
    span(class: "font-voodu-mono text-[12px] text-voodu-text-2 truncate") do
      plain prefix
      span(class: "text-voodu-muted") { "••••••••••••" }
      plain suffix
    end
  end

  def pat_scopes(p)
    scopes = Array(p["scopes"])
    div(class: "flex items-center gap-1") do
      scopes.each { |s| scope_badge(s.to_s) }
    end
  end

  def scope_badge(scope)
    accent = scope == "actions"
    span(
      class: tokens(
        "font-voodu-mono text-[10px] font-bold uppercase tracking-wider px-1.5 py-[2px] border",
        accent ? "text-voodu-accent-2 bg-voodu-accent-dim border-voodu-accent-line"
               : "text-voodu-text-2 bg-voodu-surface border-voodu-border"
      )
    ) { scope }
  end

  def pat_last_used(p)
    raw = p["last_used_at"] || p["last_used"]
    label = format_last_used(raw)
    span(class: "font-voodu-mono text-[11px] text-voodu-muted") { label }
  end

  def format_last_used(raw)
    return "never" if raw.blank?

    t = Time.parse(raw.to_s)
    secs = (Time.current - t).to_i
    return "just now" if secs < 60
    return "#{secs / 60}m ago" if secs < 3_600
    return "#{secs / 3_600}h ago" if secs < 86_400

    "#{secs / 86_400}d ago"
  rescue ArgumentError
    "—"
  end

  def pat_revoke_form(p)
    render(Components::UI::Confirmable.new(
      title: "Revoke token",
      message: %(Revoke "#{p["name"]}"? Any service still using this token will start getting 401 Unauthorized immediately.),
      confirm_label: "Revoke",
      danger: true,
      icon: :TrashOutline,
      form: {
        action: revoke_pat_settings_path(pat_id: p["id"]),
        method: :delete
      },
      trigger: {
        title: "Revoke token",
        "aria-label": "Revoke #{p["name"]}",
        class: "inline-flex items-center gap-1.5 px-2.5 h-7 border border-voodu-red/30 text-voodu-red text-[12px] font-medium hover:bg-voodu-red-dim"
      }
    )) do
      span { "Revoke" }
    end
  end

  def pat_forbidden_hint
    div(class: "px-3.5 py-4 flex items-start gap-3") do
      render Icon::LockClosedOutline.new(class: "w-4 h-4 text-voodu-muted shrink-0 mt-0.5")
      div(class: "text-[12.5px] text-voodu-text-2 leading-relaxed") do
        div(class: "font-medium text-voodu-text mb-0.5") { "Admin PAT required" }
        plain "The PAT registered for this server only has the "
        span(class: "font-voodu-mono text-voodu-muted") { "read" }
        plain " scope. Edit the server and rotate to a PAT minted with "
        span(class: "font-voodu-mono text-voodu-accent-2") { "vd pat create --scope=read,actions" }
        plain " to manage tokens from the WebUI."
      end
    end
  end

  def pat_error_hint(msg)
    div(class: "px-3.5 py-4 flex items-start gap-3") do
      render Icon::ExclamationTriangleOutline.new(class: "w-4 h-4 text-voodu-amber shrink-0 mt-0.5")
      div(class: "text-[12.5px] text-voodu-text-2") do
        div(class: "font-medium text-voodu-text mb-0.5") { "Couldn't load tokens" }
        plain msg
      end
    end
  end

  def pat_empty_hint
    div(class: "px-3.5 py-6 text-center text-voodu-muted text-[12.5px]") { "no tokens registered." }
  end

  # ── About card ───────────────────────────────────────────────────

  def about_card
    card = Components::UI::SectionCard.new(title: "About")
    card.with_action { reconnect_button }

    render card do
      div do
        render(Components::UI::KvRow.new(key: "Version")) { version_value }
        render(Components::UI::KvRow.new(key: "License")) { span(class: "font-voodu-mono") { "Apache-2.0" } }
        render(Components::UI::KvRow.new(key: "Hostname")) { agent_field("host", "hostname") }
        render(Components::UI::KvRow.new(key: "Kernel")) { agent_field("host", "kernel") }
        render(Components::UI::KvRow.new(key: "CPU cores")) { cpu_cores_value }
        render(Components::UI::KvRow.new(key: "Memory total")) { memory_total_value }
        render(Components::UI::KvRow.new(key: "Disk total")) { disk_total_value }
        render(Components::UI::KvRow.new(key: "Uptime")) { uptime_value }
        render(Components::UI::KvRow.new(key: "Boot time")) { boot_time_value }
        render(Components::UI::KvRow.new(key: "Links")) { about_links }
      end
    end
  end

  # version_value — "v0.42.1" mono + "build <sha> · <date>" muted.
  # Falls back to "—" when the agent hasn't been upgraded to a
  # build that ships voodu.version in /system.
  def version_value
    v = controller_version
    return dash if v.blank?

    span do
      span(class: "font-voodu-mono") { "v#{v}" }
    end
  end

  # about_links — docs + repository. Both open in a new tab (the
  # operator is mid-investigation; we don't want to navigate them
  # out of the dashboard).
  def about_links
    div(class: "flex items-center gap-2 flex-wrap") do
      about_link("Docs", "https://voodu.clowk.in/docs", :DocumentTextOutline)
      about_link("Repository", "https://github.com/thadeu/clowk-voodu", :CodeBracketOutline)
    end
  end

  def about_link(label, href, icon)
    icon_klass = Icon.const_get(icon)
    a(
      href: href,
      target: "_blank",
      rel: "noopener",
      class: "inline-flex items-center gap-1.5 px-2.5 h-8 border border-voodu-border bg-voodu-surface-2 text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-3 hover:text-voodu-text"
    ) do
      render icon_klass.new(class: "w-3 h-3")
      span { label }
      render Icon::ArrowTopRightOnSquareOutline.new(class: "w-2.5 h-2.5 text-voodu-muted ml-0.5")
    end
  end

  def agent_field(*path)
    v = @system&.dig(*path)
    if v.present?
      span(class: "font-voodu-mono") { v.to_s }
    else
      dash
    end
  end

  # boot_time_value — the host's last boot (UTC string from
  # /system) rendered in the operator's preferred timezone via
  # WebTime. Falls back to the raw agent value when WebTime can't
  # parse it (e.g. unexpected wire format), then to dash if the
  # field is absent altogether.
  def boot_time_value
    raw = @system&.dig("host", "boot_time")
    return dash if raw.blank?

    formatted = WebTime.strftime(raw, "%Y-%m-%d %H:%M")
    return span(class: "font-voodu-mono") { raw.to_s } if formatted.nil?

    span(class: "font-voodu-mono") { formatted }
  end

  def cpu_cores_value
    v = @system&.dig("cpu", "cores").to_i
    v.positive? ? span(class: "font-voodu-mono") { v.to_s } : dash
  end

  # memory_total_value — /system uses `mem` (not "memory"); see
  # OverviewData for the same convention.
  def memory_total_value
    bytes = @system&.dig("mem", "total_bytes").to_i
    bytes.positive? ? span(class: "font-voodu-mono") { format_bytes(bytes) } : dash
  end

  # disk_total_value — `/system.disk` is an Array of mount points
  # ({mount, used_bytes, total_bytes}). Show the root mount; if
  # there isn't one, fall back to the first entry.
  def disk_total_value
    mounts = @system&.dig("disk")
    return dash unless mounts.is_a?(Array) && mounts.any?

    root = mounts.find { |m| m["mount"] == "/" } || mounts.first
    bytes = root["total_bytes"].to_i
    return dash unless bytes.positive?

    span do
      span(class: "font-voodu-mono") { format_bytes(bytes) }
      span(class: "text-voodu-muted ml-2") { "· #{root["mount"]}" }
    end
  end

  def uptime_value
    secs = @system&.dig("host", "uptime_seconds").to_i
    secs.zero? ? dash : span(class: "font-voodu-mono") { uptime_label(secs) }
  end

  def reconnect_button
    form(
      action: reconnect_settings_path, method: "post",
      data: {turbo: false}, class: "inline-flex"
    ) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      button(
        type: "submit",
        class: "inline-flex items-center gap-1.5 px-2.5 h-7 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
      ) do
        render Icon::ArrowPathOutline.new(class: "w-3 h-3")
        span { "Reconnect" }
      end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  def dash
    span(class: "text-voodu-muted-2") { "—" }
  end

  def dot_sep
    span(class: "inline-block w-[3px] h-[3px] rounded-full bg-voodu-border-2", "aria-hidden": "true")
  end

  def age_label(secs)
    return "#{secs}s" if secs < 60
    return "#{secs / 60}m" if secs < 3_600
    return "#{secs / 3_600}h" if secs < 86_400

    days = secs / 86_400
    hours = (secs % 86_400) / 3_600
    hours.zero? ? "#{days}d" : "#{days}d #{hours}h"
  end

  def uptime_label(secs)
    days = secs / 86_400
    hours = (secs % 86_400) / 3_600
    mins = (secs % 3_600) / 60
    if days.positive?
      "#{days}d #{hours}h"
    elsif hours.positive?
      "#{hours}h #{mins}m"
    else
      "#{mins}m"
    end
  end

  def format_bytes(b)
    b = b.to_f
    return "#{b.round} B" if b < 1_000
    return "#{(b / 1_000.0).round(1)} kB" if b < 1_000_000
    return "#{(b / 1_000_000.0).round(1)} MB" if b < 1_000_000_000
    return "#{(b / 1_000_000_000.0).round(1)} GB" if b < 1_000_000_000_000

    "#{(b / 1_000_000_000_000.0).round(1)} TB"
  end
end
