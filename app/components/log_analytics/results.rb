# frozen_string_literal: true

# Components::LogAnalytics::Results — the Turbo Frame that holds the
# results table (page 1). Rendered inline by LogAnalytics::Page on first
# load and standalone by Views::LogsAnalytics::Results on a re-query, so
# the filter bar swaps just this frame in place.
#
# Top: a summary strip ("2,230 matched · 138 ms") with an honest scan-
# truncation warning when the scan itself was bounded. Below: a sticky-
# header, line-by-line table of Row components ending in a "Load more"
# trigger (ResultsBase) when older matched lines remain.
class Components::LogAnalytics::Results < Components::LogAnalytics::ResultsBase
  FRAME_ID = "logs-analytics-results"

  def initialize(data:)
    @data = data
  end

  def view_template
    turbo_frame_tag(FRAME_ID, class: "relative flex-1 min-h-0 flex flex-col gap-2.5") do
      loading_overlay
      summary_bar
      truncation_note if @data.truncated?

      if @data.empty?
        empty_state
      else
        results_table
      end
    end
  end

  private

  # loading_overlay — shown only while the frame is mid-query. Turbo sets
  # `busy` / `aria-busy` on the <turbo-frame> during the fetch and keeps
  # the previous results visible underneath; CSS (.la-results-loading in
  # theme.css) flips this overlay on for that window. Hidden on the
  # initial inline render (no fetch → no busy state).
  def loading_overlay
    div(class: "la-results-loading absolute inset-0 z-20 flex items-center justify-center gap-2 bg-voodu-bg-2/70 backdrop-blur-[1px]") do
      render Components::UI::Spinner.new(color: "var(--voodu-accent)", size: 16, stroke: 3)
      span(class: "text-[12px] font-medium text-voodu-text-2") { "Searching…" }
    end
  end

  def summary_bar
    div(class: "flex items-center justify-between gap-3") do
      div(class: "flex flex-wrap items-center gap-x-2 gap-y-1 text-[11.5px] text-voodu-muted min-w-0") do
        span do
          span(class: "font-voodu-mono text-voodu-text-2") { @data.truncated? ? "#{delimited(@data.matched)}+" : delimited(@data.matched) }
          plain " matched"
        end
        dot
        span(class: "font-voodu-mono") { "#{delimited(@data.elapsed_ms)} ms" }
      end
    end
  end

  def dot
    span(class: "text-voodu-border-2") { "·" }
  end

  # truncation_note — only when the SCAN was bounded (matched ≥
  # MATCH_SCAN_CAP). That's the one case the operator genuinely can't
  # reach everything even with Load more, so we say so. The ordinary
  # "more than one page" case needs no warning — the Load more button
  # speaks for itself.
  def truncation_note
    div(
      class: "flex items-start gap-2 px-2.5 py-1.5 border border-voodu-amber/40 bg-voodu-amber/10 text-[11px] text-voodu-text-2"
    ) do
      render Icon::ExclamationTriangleOutline.new(class: "w-3.5 h-3.5 text-voodu-amber shrink-0 mt-px")
      span do
        plain "Scan stopped at #{delimited(LogSearchData::MATCH_SCAN_CAP)} lines — there are more matches than this. Narrow the time window or add a filter, or export for the complete set."
      end
    end
  end

  def empty_state
    div(class: "flex-1 min-h-[240px] flex flex-col items-center justify-center gap-2 border border-voodu-border bg-voodu-bg-2 text-center px-6") do
      render Icon::MagnifyingGlassOutline.new(class: "w-6 h-6 text-voodu-muted-2")
      div(class: "text-[13px] text-voodu-text-2") { "No log lines match this query." }
      div(class: "text-[11.5px] text-voodu-muted") { "Widen the time window, clear the search, or check the pod scope." }
    end
  end

  def results_table
    div(class: "flex-1 min-h-0 border border-voodu-border bg-voodu-bg-2 flex flex-col overflow-hidden") do
      table_header
      div(class: "flex-1 overflow-auto min-w-0", data: { log_analytics_target: "scroller" }) do
        render_rows(@data)
        render_load_more(@data)
      end
    end
  end

  # table_header — CloudWatch-style two-column label strip (@timestamp /
  # @message), pinned above the scroll, with the row actions (jump + copy)
  # right-aligned like the live-tail column header. Labels are decorative
  # (aria-hidden); the buttons carry their own aria-labels.
  def table_header
    div(class: "flex items-center gap-3 px-2.5 py-1.5 border-b border-voodu-border bg-voodu-surface shrink-0") do
      span(class: "flex items-center gap-3 min-w-0 text-[9.5px] font-semibold uppercase tracking-[0.06em] text-voodu-muted", "aria-hidden": "true") do
        span(class: "w-3 shrink-0")
        span(class: "shrink-0") { "@timestamp" }
        span { "@message" }
      end
      div(class: "flex-1")
      header_actions
    end
  end

  # header_actions — jump to top / bottom + the Export results popover
  # (CloudWatch-style: Copy to clipboard / Download, reusing the active
  # query's filters). Pinned in the table header, reachable while scrolling.
  def header_actions
    div(class: "flex items-center gap-1 shrink-0") do
      div(class: "flex items-center gap-0.5") do
        header_icon("Jump to top",    :ArrowUpOutline,   "jumpTop")
        header_icon("Jump to bottom", :ArrowDownOutline, "jumpBottom")
      end
      export_menu
    end
  end

  def header_icon(label, icon, action)
    button(
      type:         "button",
      title:        label,
      "aria-label": label,
      data:         { action: "click->log-analytics##{action}" },
      class:        "inline-flex items-center justify-center w-6 h-6 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 transition-colors"
    ) do
      render Icon.const_get(icon).new(class: "w-3.5 h-3.5")
    end
  end

  # export_menu — Export results dropdown. Copy items fetch the export
  # endpoint and put the body on the clipboard; Download items link to it
  # (data-turbo=false so the browser handles the attachment). Both carry
  # the current query's frozen window + filters, so the file matches the
  # results on screen.
  def export_menu
    div(class: "relative", data: { controller: "dropdown" }) do
      button(
        type:  "button",
        title: "Export results",
        data:  { action: "click->dropdown#toggle" },
        class: "inline-flex items-center gap-1.5 px-2 h-6 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[11px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text transition-colors"
      ) do
        render Icon::ArrowDownTrayOutline.new(class: "w-3.5 h-3.5")
        span(class: "hidden vmd:inline") { "Export" }
        render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 opacity-70")
      end

      div(
        hidden: true,
        data:  { dropdown_target: "menu" },
        class: "absolute right-0 top-[calc(100%+4px)] z-40 min-w-[200px] border border-voodu-border-2 bg-voodu-surface shadow-2xl"
      ) do
        export_section("Copy to clipboard")
        copy_item("CSV",  "csv")
        copy_item("JSON", "json")
        copy_item("Text", "txt")
        div(class: "h-px bg-voodu-border")
        export_section("Download")
        download_item("NDJSON", "ndjson")
        download_item("CSV",    "csv")
        download_item("Text",   "txt")
      end
    end
  end

  def export_section(text)
    div(class: "px-3 pt-2 pb-1 text-[9.5px] font-semibold uppercase tracking-[0.06em] text-voodu-muted") { text }
  end

  def copy_item(label, fmt)
    button(
      type:  "button",
      data:  { action: "click->log-analytics#copyExport click->dropdown#close", export_url: export_url(fmt) },
      class: export_item_classes
    ) do
      render Icon::ClipboardDocumentOutline.new(class: "w-3.5 h-3.5 text-voodu-muted shrink-0")
      span(class: "flex-1") { label }
    end
  end

  def download_item(label, fmt)
    a(
      href:     export_url(fmt),
      download: "",
      data:     { turbo: false, action: "click->dropdown#close" },
      class:    export_item_classes
    ) do
      render Icon::ArrowDownTrayOutline.new(class: "w-3.5 h-3.5 text-voodu-muted shrink-0")
      span(class: "flex-1") { label }
    end
  end

  def export_item_classes
    "flex items-center gap-2.5 w-full px-3 py-2 min-h-[34px] text-left text-[12px] text-voodu-text hover:bg-voodu-hover"
  end

  def export_url(fmt)
    logs_analytics_export_path(
      fmt:   fmt,
      q:     @data.search.presence,
      regex: (@data.regex? ? "1" : nil),
      from:  @data.from_iso,
      until: @data.until_iso,
      pods:  @data.pods.presence
    )
  end

  def delimited(number)
    ActiveSupport::NumberHelper.number_to_delimited(number)
  end
end
