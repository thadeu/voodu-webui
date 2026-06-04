# frozen_string_literal: true

# Components::Logs::ExportStatus — drawer body for a SINGLE export's
# lifecycle. Subscribes to the export's Turbo Stream channel so the
# job's state transitions (queued → running → ready / failed) morph
# in place without a page reload.
#
# Layout:
#
#   <div p-4>                            ← outer wrapper, persists
#     <turbo-cable-stream-source …>      ← subscription, persists
#     <header row>                       ← back button + section label + status pill
#     <div id="log-export-<id>">         ← BROADCAST TARGET
#       {state-specific content}         ← replaced by job broadcasts
#     </div>
#     <params summary>                   ← persistent footer
#   </div>
#
# CRITICAL — the broadcast target receives ONLY the state-block HTML
# (via `ExportStatus.state_block_for(export)`), NOT the full
# component. Shipping the whole component would re-nest the outer
# wrapper + duplicate the back button + duplicate the cable source
# every broadcast (was the bug behind the "two New export buttons"
# screenshot). The class-method seam keeps both call sites aligned.
class Components::Logs::ExportStatus < Components::Base
  # state_block_for — class-method shim used by LogExportJob#broadcast
  # to ship JUST the state-specific HTML into the broadcast target.
  # Returns the bare markup the inner div should contain — no outer
  # wrapper, no cable source, no back button.
  def self.state_block_for(export)
    new(export: export, inner_only: true).call
  end

  # inner_only — controls which slice of markup view_template emits.
  # `false` (default) renders the full drawer body (wrapper, back
  # button, broadcast-target div with state block, params summary).
  # `true` renders ONLY the state block, for broadcast updates.
  def initialize(export:, inner_only: false)
    @export     = export
    @inner_only = inner_only
  end

  def view_template
    return state_block if @inner_only

    div(class: "p-4 flex flex-col gap-3.5") do
      raw(safe(turbo_cable_source_tag))
      header_row

      div(id: "log-export-#{@export.id}", class: "flex flex-col gap-3") do
        state_block
      end

      params_summary
    end
  end

  private

  # header_row — matches the PodsPicker drawer pattern: back chip on
  # the left, "EXPORT" section label, hairline separator, status
  # pill on the right. Compact (h-px line) so the header itself
  # doesn't steal vertical space from the state card below.
  def header_row
    div(class: "flex items-center gap-2.5") do
      back_to_filter_chip
      span(
        class: "text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted shrink-0"
      ) { "Export" }
      span(class: "flex-1 h-px bg-voodu-border")
      status_pill
    end
  end

  # back_to_filter_chip — "New export" anchor that turbo_streams a
  # fresh ExportDrawer into `#log-export-drawer-body` (the parent
  # ExportDrawer's root id). Lets the operator return to the filter
  # without closing/reopening the drawer.
  def back_to_filter_chip
    a(
      href: new_export_url,
      data: { turbo_stream: "true" },
      title: "Back to filter",
      class: "inline-flex items-center gap-1 px-2 h-6 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[11px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text transition-colors shrink-0"
    ) do
      raw(safe(arrow_left_svg))
      span { "New" }
    end
  end

  # status_pill — colored dot + label matching the export's state.
  # Replaces the old block-level state_header that doubled up with
  # the green Ready card below.
  def status_pill
    label, color = status_label_and_color
    span(class: "inline-flex items-center gap-1.5 shrink-0") do
      span(
        class: "inline-block w-2 h-2 rounded-full",
        style: "background: #{color}; box-shadow: 0 0 0 3px color-mix(in srgb, #{color} 18%, transparent);"
      )
      span(class: "text-[11px] uppercase tracking-wide text-voodu-muted-2 font-voodu-mono") { label }
    end
  end

  def status_label_and_color
    case @export.status
    when "queued"  then ["Queued",  "var(--voodu-muted)"]
    when "running" then ["Running", "var(--voodu-amber)"]
    when "ready"   then ["Ready",   "var(--voodu-green)"]
    when "failed"  then ["Failed",  "var(--voodu-red)"]
    else                ["—",       "var(--voodu-muted)"]
    end
  end

  def state_block
    case @export.status
    when "queued"  then queued_state
    when "running" then running_state
    when "ready"   then ready_state
    when "failed"  then failed_state
    else                queued_state
    end
  end

  def queued_state
    div(class: "flex items-center gap-2 px-3 py-2.5 border border-voodu-border bg-voodu-surface text-[12.5px] text-voodu-text-2") do
      span(
        class: "inline-block w-1.5 h-1.5 rounded-full bg-voodu-muted shrink-0"
      )
      span { "Queued — picking up the job shortly." }
    end
  end

  def running_state
    div(class: "flex items-center gap-2 px-3 py-2.5 border border-voodu-border bg-voodu-surface text-[12.5px] text-voodu-text-2") do
      render Components::UI::Spinner.new(color: "var(--voodu-amber)", size: 12)
      span { "Reading warehouse files…" }
    end
  end

  def ready_state
    div(class: "flex flex-col gap-2.5 px-3 py-3 border border-voodu-green/40 bg-voodu-green-dim") do
      div(class: "flex items-center gap-2 text-[12.5px] text-voodu-text") do
        render Icon::CheckCircleOutline.new(class: "w-3.5 h-3.5 text-voodu-green")
        span(class: "font-medium") { "Export ready" }
        span(class: "flex-1")
        span(class: "text-[11px] text-voodu-muted") do
          plain "expires in "
          span(class: "font-voodu-mono") { time_until(@export.expires_at) }
        end
      end
      div(class: "text-[11.5px] text-voodu-muted") do
        span(class: "font-voodu-mono text-voodu-text-2") { @export.line_count.to_s }
        plain " lines · "
        span(class: "font-voodu-mono text-voodu-text-2") { format_bytes(@export.file_size_bytes) }
      end
      a(
        href: download_url,
        class: "inline-flex items-center justify-center gap-1.5 px-3 h-8 border border-voodu-accent-line bg-voodu-accent text-voodu-on-accent text-[12px] font-medium hover:bg-voodu-accent-2 self-start"
      ) do
        render Icon::ArrowDownTrayOutline.new(class: "w-3.5 h-3.5")
        span { "Download" }
      end
    end
  end

  def failed_state
    div(class: "flex flex-col gap-2.5 px-3 py-3 border border-voodu-red/40 bg-voodu-red-dim") do
      div(class: "flex items-center gap-2 text-[12.5px] text-voodu-red") do
        render Icon::ExclamationTriangleOutline.new(class: "w-3.5 h-3.5")
        span(class: "font-medium") { "Export failed" }
      end
      div(class: "text-[11.5px] text-voodu-text-2 font-voodu-mono break-words") do
        plain @export.error.to_s
      end
    end
  end

  # ── Params summary (always visible) ──────────────────────────

  def params_summary
    div(class: "flex flex-col gap-0.5 text-[11px] text-voodu-muted border-t border-voodu-border pt-3") do
      kv_row("Period", period_label)
      kv_row("Pods",   pods_label)
      kv_row("Search", search_label)
      kv_row("Format", format_label)
    end
  end

  def kv_row(key, value)
    div(class: "flex items-baseline gap-2 min-w-0") do
      span(class: "text-voodu-muted shrink-0 w-14") { key }
      span(class: "font-voodu-mono text-voodu-text-2 truncate") { value }
    end
  end

  # ── Raw helpers (no view_context) ───────────────────────────

  def turbo_cable_source_tag
    signed = Turbo::StreamsChannel.signed_stream_name("log-export-#{@export.id}")
    %(<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name="#{signed}"></turbo-cable-stream-source>)
  end

  def arrow_left_svg
    %(<svg viewBox="0 0 16 16" width="11" height="11" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10 4L6 8L10 12"/></svg>)
  end

  def tenant_key
    @export.island.key
  end

  def download_url
    "/#{tenant_key}/exports/#{@export.id}/download"
  end

  def new_export_url
    pod = @export.pods.first
    qs  = { embed: 1 }
    qs[:pod] = pod if pod.present? && !@export.all_pods?
    "/#{tenant_key}/exports/new?#{qs.to_query}"
  end

  # ── Param formatters ────────────────────────────────────────

  def period_label
    f = @export.from_time
    u = @export.until_time
    return "—" if f.nil? || u.nil?

    "#{WebTime.strftime(f, '%Y-%m-%d %H:%M')} → #{WebTime.strftime(u, '%Y-%m-%d %H:%M')}"
  end

  def pods_label
    @export.all_pods? ? "All pods" : @export.pods.join(", ")
  end

  def search_label
    s = @export.content_search
    return "—" if s.blank?

    @export.content_regex? ? "/#{s}/i (regex)" : s
  end

  def format_label
    inner = case @export.format
            when "txt" then "Plain text"
            when "csv" then "CSV"
            else            "NDJSON"
            end

    @export.group_by_pod? ? "ZIP · #{inner} per pod" : inner
  end

  def format_bytes(bytes)
    b = bytes.to_i
    return "—"                          if b.zero?
    return "#{b} B"                     if b < 1024
    return "#{(b / 1024.0).round(1)} KB" if b < 1024 * 1024
    return "#{(b / 1024.0 / 1024.0).round(1)} MB" if b < 1024 * 1024 * 1024

    "#{(b / 1024.0 / 1024.0 / 1024.0).round(2)} GB"
  end

  def time_until(target)
    return "—" if target.nil?

    secs = (target - Time.current).to_i
    return "expired" if secs.negative?
    return "#{secs}s" if secs < 60
    return "#{secs / 60}m" if secs < 3600
    return "#{secs / 3600}h" if secs < 86_400

    "#{secs / 86_400}d"
  end
end
