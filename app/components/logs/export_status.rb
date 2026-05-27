# frozen_string_literal: true

# Components::Logs::ExportStatus — drawer body for a SINGLE export's
# lifecycle. Subscribes to the export's Turbo Stream channel so the
# job's state transitions (queued → running → ready / failed) morph
# in place without a page reload.
#
# Wrapper layout:
#
#   <div>                                ← outer wrapper, persists
#     <turbo-cable-stream-source …>      ← subscription, persists
#     <div id="log-export-<id>">         ← BROADCAST TARGET — replaced
#       {state-specific content}
#     </div>
#   </div>
#
# When LogExportJob#broadcast fires `broadcast_update_to("log-export-<id>",
# target: "log-export-<id>", html: …)`, Turbo replaces the INNER HTML
# of `<div id="log-export-<id>">`. The wrapper + subscription stay
# intact across every state update.
#
# This component is ALSO returned by the form-submit `create` response
# (turbo_stream.update("log-export-drawer-body", …)) — same call site
# can render the initial post-submit state and every subsequent
# broadcast.
class Components::Logs::ExportStatus < Components::Base
  def initialize(export:)
    @export = export
  end

  def view_template
    # NO outer `id="log-export-drawer-body"` here — ExportDrawer
    # already owns that id as the broadcast target. If we duplicated
    # it, `turbo_stream.update("log-export-drawer-body", html)` would
    # nest a second `#log-export-drawer-body` inside the original
    # (Turbo replaces innerHTML; it doesn't unwrap) and the operator
    # would see nothing because of the duplicate-id ambiguity.
    #
    # Just the padded body + the subscription tag + the status
    # target. Subscription is OUTSIDE `#log-export-<id>` so the
    # job's broadcast (which targets the inner id) replaces only
    # the visible state, not the cable connection.
    div(class: "p-6 flex flex-col gap-5") do
      # Emitted as raw HTML using the Turbo helper to compute the
      # signed stream name (static method, no view_context
      # dependency) — this component is callable from BOTH the
      # controller (with view_context) AND LogExportJob#broadcast
      # (without one).
      raw(safe(turbo_cable_source_tag))

      div(id: "log-export-#{@export.id}", class: "flex flex-col gap-5") do
        state_block
      end
    end
  end

  private

  # turbo_cable_source_tag — manually emits the <turbo-cable-stream-
  # source> custom element that turbo_stream_from would generate.
  # `signed_stream_name` is a class method on Turbo::StreamsChannel
  # so it works without a view_context.
  def turbo_cable_source_tag
    signed = Turbo::StreamsChannel.signed_stream_name("log-export-#{@export.id}")
    %(<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name="#{signed}"></turbo-cable-stream-source>)
  end

  # tenant_key + manual URL builders — same reason as above: avoid
  # path helpers (which need view_context). Routes are stable enough
  # that hard-coding the prefix is fine; if they ever change, the
  # helper-using callers (form action in ExportDrawer) would break
  # first and surface the drift.
  def tenant_key
    @export.island.key
  end

  def download_url
    "/#{tenant_key}/exports/#{@export.id}/download"
  end

  def retry_url
    "/#{tenant_key}/exports/new"
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
    state_header(:queued)
    p(class: "text-[13px] text-voodu-text-2") do
      plain "Export queued — picking up the job shortly."
    end
    params_summary
  end

  def running_state
    state_header(:running)
    div(class: "flex items-center gap-2 text-[13px] text-voodu-text-2") do
      render Components::UI::Spinner.new(color: "var(--voodu-accent)", size: 14)
      span { "Reading warehouse files…" }
    end
    params_summary
  end

  def ready_state
    state_header(:ready)

    div(class: "flex flex-col gap-3 px-4 py-3 border border-voodu-green/40 bg-voodu-green-dim") do
      div(class: "flex items-center gap-2 text-[13px] text-voodu-text") do
        render Icon::CheckCircleOutline.new(class: "w-4 h-4 text-voodu-green")
        span(class: "font-medium") { "Export ready" }
      end
      div(class: "text-[12.5px] text-voodu-text-2") do
        span { "Matched " }
        span(class: "font-voodu-mono text-voodu-text") { @export.line_count.to_s }
        span { " lines · " }
        span(class: "font-voodu-mono text-voodu-text") { format_bytes(@export.file_size_bytes) }
      end
      a(
        href: download_url,
        class: "inline-flex items-center justify-center gap-1.5 px-3 h-9 border border-voodu-accent-line bg-voodu-accent text-white text-[12.5px] font-medium hover:bg-voodu-accent-2 self-start"
      ) do
        render Icon::ArrowDownTrayOutline.new(class: "w-3.5 h-3.5")
        span { "Download" }
      end
      div(class: "text-[11.5px] text-voodu-muted") do
        plain "Expires in "
        span(class: "font-voodu-mono") { time_until(@export.expires_at) }
      end
    end

    params_summary
  end

  def failed_state
    state_header(:failed)
    div(class: "flex flex-col gap-3 px-4 py-3 border border-voodu-red/40 bg-voodu-red-dim") do
      div(class: "flex items-center gap-2 text-[13px] text-voodu-red") do
        render Icon::ExclamationTriangleOutline.new(class: "w-4 h-4")
        span(class: "font-medium") { "Export failed" }
      end
      div(class: "text-[12px] text-voodu-text-2 font-voodu-mono break-words") do
        plain @export.error.to_s
      end
      a(
        href: retry_url,
        data: { turbo_frame: "_top" },
        class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text self-start"
      ) do
        render Icon::ArrowPathOutline.new(class: "w-3.5 h-3.5")
        span { "Try again" }
      end
    end

    params_summary
  end

  def state_header(state)
    label, color = case state
    when :queued  then ["Queued",     "var(--voodu-muted)"]
    when :running then ["Running",    "var(--voodu-amber)"]
    when :ready   then ["Ready",      "var(--voodu-green)"]
    when :failed  then ["Failed",     "var(--voodu-red)"]
    end

    div(class: "flex items-center gap-2") do
      span(
        class: "inline-block w-2 h-2 rounded-full",
        style: "background: #{color}; box-shadow: 0 0 0 3px color-mix(in srgb, #{color} 18%, transparent);"
      )
      span(class: "text-[11px] uppercase tracking-wide text-voodu-muted font-voodu-mono") { label }
    end
  end

  def params_summary
    div(class: "flex flex-col gap-1 mt-1 text-[11.5px] text-voodu-muted") do
      div { plain_kv("Period", period_label) }
      div { plain_kv("Pods",   pods_label) }
      div { plain_kv("Search", search_label) }
      div { plain_kv("Format", format_label) }
    end
  end

  def plain_kv(key, value)
    span(class: "text-voodu-muted") { "#{key}: " }
    span(class: "font-voodu-mono text-voodu-text-2") { value }
  end

  def period_label
    f = @export.from_time
    u = @export.until_time
    return "—" if f.nil? || u.nil?

    "#{f.strftime('%Y-%m-%d %H:%M')} → #{u.strftime('%Y-%m-%d %H:%M')}"
  end

  def pods_label
    @export.all_pods? ? "All pods" : @export.pods.join(", ")
  end

  def search_label
    s = @export.content_search
    return "—" if s.blank?

    @export.content_regex? ? "/#{s}/i (regex)" : s
  end

  # format_label — combines the inner format (ndjson/txt/csv) with
  # the optional ZIP wrapping so the operator can tell at a glance
  # what they're about to download.
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
