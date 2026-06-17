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
  include Components::LogAnalytics::ColumnChrome

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

  # body_header_actions — the results-table toolbar lives in the MESSAGE
  # header cell (ColumnChrome calls this hook there). The modal leaves it
  # empty.
  def body_header_actions
    header_actions
  end

  def summary_bar
    div(class: "flex items-center justify-between gap-3") do
      div(class: "flex flex-wrap items-center gap-x-2 gap-y-1 text-[11.5px] text-voodu-muted min-w-0",
          data: { log_analytics_target: "summary" }) do
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
    # `relative` anchors the column-visibility popover; the logs-columns
    # controller (shared with the live tail) owns the resize drag + the hide
    # popover over the `.log-list` inside. column_grid_attrs (ColumnChrome)
    # carries the shared storage key / column set / default widths — the
    # SAME the Surrounding modal uses, so the layout stays in lockstep.
    div(
      class: "relative flex-1 min-h-0 border border-voodu-border bg-voodu-bg-2 flex flex-col overflow-hidden",
      data:  column_grid_attrs
    ) do
      div(class: "flex-1 overflow-auto min-w-0", data: { log_analytics_target: "scroller" }) do
        # ONE `.log-list` grid for the whole result set: the column header
        # (ColumnChrome) + every row share column tracks (alignment). The
        # Load more frames live INSIDE the grid (display:contents, see
        # theme.css) so appended pages flow into the same tracks.
        div(class: "log-list la-list") do
          column_header
          render_rows(@data)
          render_load_more(@data)
        end
      end
      column_visibility_popover
    end
  end

  # header_actions — jump to top / bottom + the Export results popover
  # (CloudWatch-style: Copy to clipboard / Download, reusing the active
  # query's filters). Pinned in the table header, reachable while scrolling.
  def header_actions
    div(class: "flex items-center gap-1 shrink-0") do
      # Column-shaping actions grouped: wrap toggles the lines (truncate ↔
      # full); the gear opens the visibility popover. Copying lives in the
      # Export popover — its "Copy to clipboard" covers the whole query, so
      # a separate "copy visible" icon would just be redundant.
      div(class: "flex items-center gap-0.5") do
        wrap_toggle
        column_settings_button
      end
      header_icon("Clear results", :BackspaceOutline, "clear")
      div(class: "flex items-center gap-0.5") do
        header_icon("Jump to top",    :ArrowUpOutline,   "jumpTop")
        header_icon("Jump to bottom", :ArrowDownOutline, "jumpBottom")
      end
      export_menu
    end
  end

  # wrap_toggle — flips wrap on every collapsed line (truncate ↔ full,
  # wrapping). `data-active` lights it accent-green when on; the
  # log-analytics controller toggles the `.log-wrap` class on the grid
  # `.log-list` (same rule the live tail uses) and persists the choice so
  # it survives a re-query frame swap.
  def wrap_toggle
    button(
      type:         "button",
      "aria-label": "Toggle wrap on all lines",
      "aria-pressed": "false",
      data:         {
        action:              "click->log-analytics#toggleWrap",
        log_analytics_target: "wrapToggle",
        tooltip:             "Toggle wrap",
        active:              "false"
      },
      class: "la-wrap-toggle inline-flex items-center justify-center w-6 h-6 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 transition-colors data-[active=true]:text-voodu-accent-2 data-[active=true]:bg-voodu-accent-dim"
    ) do
      svg(
        viewBox: "0 0 16 16", fill: "none", stroke: "currentColor",
        "stroke-width": "1.5", "stroke-linecap": "round", "stroke-linejoin": "round",
        class: "w-3.5 h-3.5", "aria-hidden": "true"
      ) do |s|
        s.line(x1: "2", y1: "4", x2: "14", y2: "4")
        s.path(d: "M2 8h10a2 2 0 0 1 0 4H7")
        s.polyline(points: "9,10 7,12 9,14")
        s.line(x1: "2", y1: "12", x2: "4", y2: "12")
      end
    end
  end

  # column_settings_button — opens the visibility popover (logs-columns
  # controller). aria-expanded drives the active tint via theme.css.
  def column_settings_button
    button(
      type:          "button",
      "aria-label":  "Choose visible columns",
      "aria-expanded": "false",
      data:          {
        action:              "click->logs-columns#togglePopover",
        logs_columns_target: "settingsButton",
        tooltip:             "Columns"
      },
      class: "inline-flex items-center justify-center w-6 h-6 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 transition-colors aria-expanded:text-voodu-accent-2 aria-expanded:bg-voodu-accent-dim"
    ) do
      render Icon::ViewColumnsOutline.new(class: "w-3.5 h-3.5")
    end
  end

  # column_visibility_popover — modal-less popover (logs-columns target),
  # a sibling of the scroller so it escapes the overflow clip. MESSAGE is
  # required (permanently checked + disabled): it's the only column that
  # carries the actual log line.
  def column_visibility_popover
    div(
      class:        "log-cols-popover",
      hidden:       true,
      role:         "menu",
      "aria-label": "Visible columns",
      data:         { logs_columns_target: "popover" }
    ) do
      div(class: "log-cols-popover-title") { "Visible columns" }
      column_visibility_row("ts",   "Time")
      column_visibility_row("pod",  "Pod")
      column_visibility_row("body", "Message", required: true)
    end
  end

  def column_visibility_row(key, label, required: false)
    label(class: required ? "log-cols-popover-row is-required" : "log-cols-popover-row") do
      input(
        type:     "checkbox",
        checked:  true,
        disabled: required,
        data: {
          action:              "change->logs-columns#toggleVisibility",
          column_key:          key,
          required:            required ? "true" : "false",
          logs_columns_target: "visibilityToggle"
        }
      )
      span(class: "log-cols-popover-label") { label }
      span(class: "log-cols-popover-hint") { "required" } if required
    end
  end

  def header_icon(label, icon, action)
    button(
      type:         "button",
      "aria-label": label,
      data:         { action: "click->log-analytics##{action}", tooltip: label },
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
