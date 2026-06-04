# frozen_string_literal: true

# Components::Logs::ExportDrawer — drawer body for creating a NEW
# log export. Renders the form with four sections: period, pods,
# content search, output format.
#
# Submitting POSTs to `exports_path` with `data-turbo-stream` so
# the response (turbo_stream.update of `log-export-drawer-body`)
# swaps the form for a Components::Logs::ExportStatus block —
# operator never leaves the drawer.
#
# The form is wrapped in `<div id="log-export-drawer-body">` so
# both the create response AND the broadcast-driven status updates
# (from LogExportJob) can target the same DOM node.
class Components::Logs::ExportDrawer < Components::Base
  # 7d preset removed — retention is 2d, so anything older isn't
  # available. Yesterday + Last 24h + Last 2d covers the typical
  # debug flow ("what happened during X yesterday?").
  PERIOD_PRESETS = [
    { id: "last_15m", label: "Last 15m",  duration: 15.minutes  },
    { id: "last_1h",  label: "Last 1h",   duration: 1.hour      },
    { id: "today",    label: "Today",     duration: :today      },
    { id: "yesterday",label: "Yesterday", duration: :yesterday  },
    { id: "last_24h", label: "Last 24h",  duration: 24.hours    },
    { id: "last_2d",  label: "Last 2d",   duration: 2.days      }
  ].freeze

  KIND_LABELS = {
    "deployment"  => "Deployments",
    "statefulset" => "StatefulSets",
    "job"         => "Jobs",
    "cronjob"     => "Cronjobs"
  }.freeze

  def initialize(pods:, current_pod:, current_island:, recent_exports: [])
    @pods            = pods            # { "deployment" => [Pod, ...], ... }
    @current_pod     = current_pod
    @current_island  = current_island
    @recent_exports  = recent_exports
  end

  def view_template
    div(id: "log-export-drawer-body", class: "flex flex-col h-full") do
      form(
        action: exports_path,
        method: "post",
        data:   {
          turbo:      true,
          controller: "export-form",
          # Normalise the from/until inputs from browser-local time
          # to UTC ISO BEFORE Turbo submits. Without this, an
          # operator in BRT (UTC-3) picking "Last 1h" sends
          # "20:30" → server parses as 20:30 UTC → no logs match
          # (they're timestamped in real UTC, 23:30Z).
          action:     "submit->export-form#normalizeDates"
        },
        class:  "flex flex-col flex-1 min-h-0"
      ) do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)

        div(class: "flex-1 min-h-0 overflow-auto scrollbar-hidden px-4 py-4 flex flex-col gap-5") do
          recent_section if @recent_exports.any?
          period_section
          pods_section
          content_section
          output_section
        end

        footer_section
      end
    end
  end

  private

  # ── Recent exports ───────────────────────────────────────────────
  # Survives the "I closed the drawer mid-job, where's my download?"
  # case. Each row links to the export's standalone page (which
  # carries the same status block + subscription, so even running
  # jobs continue to update live there).
  def recent_section
    section_block("Recent exports") do
      div(class: "flex flex-col") do
        @recent_exports.each_with_index do |export, idx|
          recent_row(export, idx)
        end
      end
    end
  end

  def recent_row(export, idx)
    border = idx.zero? ? "" : "border-t border-voodu-border"
    div(class: "flex items-center gap-2 py-2 #{border}") do
      status_dot(export.status)

      div(class: "flex-1 min-w-0 flex flex-col gap-0.5") do
        div(class: "text-[12px] text-voodu-text-2 truncate") do
          span(class: "font-voodu-mono") { "##{export.id}" }
          span(class: "text-voodu-muted") { " · " }
          span { recent_period_label(export) }
        end
        div(class: "text-[11px] text-voodu-muted truncate") do
          span { recent_pods_label(export) }
          span(class: "text-voodu-border-2 mx-1") { "·" }
          span(class: "font-voodu-mono uppercase") { recent_format_label(export) }
        end
      end

      recent_action(export)
    end
  end

  def status_dot(status)
    color = case status
            when "ready"   then "var(--voodu-green)"
            when "running" then "var(--voodu-amber)"
            when "failed"  then "var(--voodu-red)"
            else                "var(--voodu-muted)"
            end

    span(
      class: "inline-block w-1.5 h-1.5 rounded-full shrink-0",
      style: "background: #{color};",
      title: status.capitalize
    )
  end

  def recent_action(export)
    if export.ready?
      a(
        href:  download_export_path(id: export.id),
        title: "Download #{format_bytes(export.file_size_bytes)}",
        class: "inline-flex items-center gap-1 px-2 h-7 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[11.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text shrink-0"
      ) do
        render Icon::ArrowDownTrayOutline.new(class: "w-3 h-3")
        span { format_bytes(export.file_size_bytes) }
      end
    else
      a(
        href:  export_path(id: export.id),
        title: export.failed? ? export.error.to_s : "Open in new tab",
        target: "_blank",
        rel:   "noopener",
        class: "inline-flex items-center gap-1 px-2 h-7 text-[11.5px] text-voodu-text-2 hover:text-voodu-text shrink-0"
      ) do
        span { export.status.capitalize }
        render Icon::ArrowTopRightOnSquareOutline.new(class: "w-3 h-3")
      end
    end
  end

  def recent_period_label(export)
    f = export.from_time
    u = export.until_time
    return "—" if f.nil? || u.nil?

    same_day = f.to_date == u.to_date

    if same_day
      "#{WebTime.strftime(f, '%b %-d %H:%M')}–#{WebTime.strftime(u, '%H:%M')}"
    else
      "#{WebTime.strftime(f, '%b %-d %H:%M')} → #{WebTime.strftime(u, '%b %-d %H:%M')}"
    end
  end

  def recent_pods_label(export)
    if export.all_pods?
      "All pods"
    elsif export.pods.size == 1
      export.pods.first
    else
      "#{export.pods.size} pods"
    end
  end

  # recent_format_label — short, uppercase chip that mirrors what's
  # on the file extension. Group-by-pod exports get a "ZIP · NDJSON"
  # combo so the operator knows both the wrapper and the inner
  # format at a glance.
  def recent_format_label(export)
    inner = export.format.to_s
    export.group_by_pod? ? "ZIP · #{inner}" : inner
  end

  def format_bytes(bytes)
    b = bytes.to_i
    return "—" if b.zero?
    return "#{b} B" if b < 1024
    return "#{(b / 1024.0).round(1)} KB" if b < 1024 * 1024
    return "#{(b / 1024.0 / 1024.0).round(1)} MB" if b < 1024 * 1024 * 1024

    "#{(b / 1024.0 / 1024.0 / 1024.0).round(2)} GB"
  end

  # ── Period ────────────────────────────────────────────────────────
  def period_section
    section_block("Period") do
      div(class: "flex flex-wrap gap-1.5") do
        PERIOD_PRESETS.each { |p| preset_chip(p) }
      end

      div(class: "grid grid-cols-2 gap-2") do
        labeled_input("From",  "from",  default_from)
        labeled_input("Until", "until", default_until)
      end

      div(class: "text-[11px] text-voodu-muted") do
        plain "Window must be ≤ 2 days (retention). Older data has been reaped."
      end
    end
  end

  def preset_chip(preset)
    button(
      type:  "button",
      data:  {
        action:        "click->export-form#applyPreset",
        preset_id:     preset[:id]
      },
      class: "inline-flex items-center px-2.5 h-7 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[11.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) { preset[:label] }
  end

  def labeled_input(label, name, value)
    label_el = -> {
      div(class: "text-[11px] text-voodu-muted mb-1") { label }
    }

    label(class: "flex flex-col") do
      label_el.call
      input(
        type:  "datetime-local",
        name:  name,
        value: value,
        data:  { export_form_target: name == "from" ? "fromInput" : "untilInput" },
        class: "px-2.5 h-9 border border-voodu-border bg-voodu-surface text-voodu-text text-[12.5px] outline-none focus:border-voodu-accent"
      )
    end
  end

  def default_from
    1.hour.ago.strftime("%Y-%m-%dT%H:%M")
  end

  def default_until
    Time.current.strftime("%Y-%m-%dT%H:%M")
  end

  # ── Pods ──────────────────────────────────────────────────────────
  def pods_section
    section_block("Pods") do
      div(class: "flex flex-col gap-1.5") do
        all_pods_row
        if @pods.any?
          div(class: "flex flex-col gap-2 mt-1") do
            @pods.each { |kind, list| kind_group(kind, list) }
          end
        else
          div(class: "text-[12px] text-voodu-muted") do
            plain "No pods recorded for this island yet. Pick a period after some logs have been captured."
          end
        end
      end
    end
  end

  def all_pods_row
    label(class: "flex items-center gap-2 cursor-pointer") do
      input(
        type:    "checkbox",
        name:    "all_pods_toggle",
        value:   "1",
        checked: @current_pod.blank?,
        data:    { action: "change->export-form#toggleAll" },
        class:   "w-3.5 h-3.5 accent-voodu-accent"
      )
      span(class: "text-[12.5px] text-voodu-text font-medium") { "All pods" }
      span(class: "text-[11px] text-voodu-muted") { "(#{pod_total} total)" }
    end
  end

  def kind_group(kind, list)
    title = KIND_LABELS[kind] || kind.to_s.capitalize
    div(class: "flex flex-col gap-1 mt-2") do
      div(class: "flex items-center justify-between") do
        span(class: "text-[11px] uppercase tracking-wide text-voodu-muted font-voodu-mono") do
          plain "#{title} (#{list.size})"
        end
        label(class: "inline-flex items-center gap-1.5 cursor-pointer") do
          input(
            type:  "checkbox",
            data:  {
              action: "change->export-form#toggleKind",
              kind:   kind
            },
            class: "w-3 h-3 accent-voodu-accent"
          )
          span(class: "text-[11px] text-voodu-text-2") { "Select all" }
        end
      end

      div(class: "flex flex-col gap-0.5 pl-1") do
        list.each { |pod| pod_row(pod, kind) }
      end
    end
  end

  def pod_row(pod, kind)
    label(class: "flex items-center gap-2 px-1 py-0.5 hover:bg-voodu-surface-2 cursor-pointer") do
      input(
        type:    "checkbox",
        name:    "pods[]",
        value:   pod.container_name,
        checked: @current_pod == pod.container_name,
        data:    {
          export_form_target: "podCheckbox",
          kind:                kind
        },
        class:   "w-3.5 h-3.5 accent-voodu-accent"
      )
      span(class: "text-[12px] text-voodu-text-2 font-voodu-mono break-all") { pod.container_name }
    end
  end

  def pod_total
    @pods.values.sum(&:size)
  end

  # ── Content search ────────────────────────────────────────────────
  def content_section
    section_block("Content search", subtitle: "Optional. Matches message + raw line.") do
      input(
        type:        "text",
        name:        "content_search",
        placeholder: "e.g. user_id=42 or a request id",
        class:       "px-2.5 h-9 border border-voodu-border bg-voodu-surface text-voodu-text text-[12.5px] outline-none focus:border-voodu-accent w-full font-voodu-mono"
      )
      label(class: "flex items-center gap-2 cursor-pointer text-[11.5px] text-voodu-text-2 mt-1.5") do
        input(type: "checkbox", name: "regex", value: "1", class: "w-3.5 h-3.5 accent-voodu-accent")
        span { "Regex (case-insensitive when off)" }
      end
    end
  end

  # ── Output ────────────────────────────────────────────────────────
  #
  # FORMATS (operator decision, see chat):
  #   - ndjson: one JSON object per line. Structured. Good for jq,
  #             elastic ingest, programmatic post-processing.
  #   - txt:    "ISO_TS [pod] LEVEL msg" per line. Readable. Good
  #             for paste-into-ticket and tail/grep.
  #   - csv:    ts,pod,stream,level,msg. Good for Excel / planilhas
  #             and pivot-table style review.
  FORMATS = [
    { id: "ndjson", label: "NDJSON",      hint: "Structured, one JSON per line" },
    { id: "txt",    label: "Plain text",  hint: "Readable, one log line each"  },
    { id: "csv",    label: "CSV",         hint: "Spreadsheet (ts, pod, level, msg)" }
  ].freeze

  def output_section
    section_block("Output") do
      div(class: "flex flex-col gap-1.5") do
        FORMATS.each_with_index { |f, idx| format_radio(f, idx.zero?) }
      end

      label(class: "flex items-center gap-2 cursor-pointer text-[11.5px] text-voodu-text-2 mt-2") do
        input(type: "checkbox", name: "group_by_pod", value: "1", class: "w-3.5 h-3.5 accent-voodu-accent")
        span { "Group by pod (.zip with one file per pod)" }
      end
    end
  end

  def format_radio(fmt, default)
    label(class: "flex items-center gap-2 cursor-pointer px-2 py-1 hover:bg-voodu-surface-2") do
      # name="output_format" (NOT "format"): `format` is reserved in
      # Rails — when submitted as a param, Rails treats it as the
      # request format override and tries to find a matching Mime
      # type. `format=ndjson` → no matching Mime → 406 + drawer
      # closes with a full-page error. The controller maps
      # output_format → params_hash["format"] for the rest of the
      # pipeline.
      input(
        type:    "radio",
        name:    "output_format",
        value:   fmt[:id],
        checked: default,
        class:   "w-3.5 h-3.5 accent-voodu-accent"
      )
      span(class: "text-[12.5px] text-voodu-text font-medium w-[88px]") { fmt[:label] }
      span(class: "text-[11px] text-voodu-muted") { fmt[:hint] }
    end
  end

  # ── Footer ────────────────────────────────────────────────────────
  def footer_section
    footer(class: "flex items-center gap-2 px-4 py-3 border-t border-voodu-border bg-voodu-bg-2 shrink-0") do
      div(class: "flex-1 text-[11px] text-voodu-muted") do
        plain "Max 50,000 matched lines · 30s timeout"
      end
      button(
        type:  "submit",
        class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-accent-line bg-voodu-accent text-voodu-on-accent text-[12.5px] font-medium hover:bg-voodu-accent-2"
      ) do
        render Icon::ArrowDownTrayOutline.new(class: "w-3.5 h-3.5")
        span { "Generate export" }
      end
    end
  end

  # ── Shared chrome ─────────────────────────────────────────────────
  # NOTE: no `data-controller="export-form"` here — the controller
  # is registered ONCE on the form root (see view_template). Multiple
  # instances of the same controller were creating scope confusion
  # (Period section's instance couldn't see Pods section's targets
  # and vice-versa, and submit-time normalisation needed a single
  # owner of the form).
  def section_block(title, subtitle: nil, &block)
    div(class: "flex flex-col gap-2") do
      div do
        h3(class: "m-0 text-[11px] uppercase tracking-wide text-voodu-muted font-voodu-mono") { title }
        div(class: "text-[11px] text-voodu-muted mt-0.5") { subtitle } if subtitle
      end
      div(class: "flex flex-col gap-1.5", &block)
    end
  end
end
