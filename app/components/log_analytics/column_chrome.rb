# frozen_string_literal: true

# Components::LogAnalytics::ColumnChrome — the column-grid scaffolding shared
# by the analytics results table AND the Surrounding Logs modal, so the two
# stay in lockstep: the same `.log-list` grid contract, the same logs-columns
# wiring (ONE storage key → the operator's hide/resize layout applies to both
# surfaces), the same sticky column header with resize handles, and the same
# loading/rendering overlay.
#
# A host renders `column_grid_attrs` on its (relative) container, the
# `loading_overlay`, then a `.log-list.la-list` holding `column_header` plus
# its rows. The results table mounts its toolbar in the MESSAGE header cell by
# overriding `body_header_actions`; the modal leaves it empty.
module Components::LogAnalytics::ColumnChrome
  # Shared logs-columns config. The storage key is the SAME on both surfaces
  # so hiding/resizing a column in the table is reflected in the modal (and
  # vice versa). `body` stays last (the 1fr payload). Fixed default widths so
  # the grid skips the auto content-measure over thousands of rows; keep in
  # sync with `.log-list.la-list` in theme.css.
  COLUMN_STORAGE_KEY = "voodu:logs-analytics-columns:v1"
  COLUMN_KEYS = %w[ts pod body].freeze
  COLUMN_DEFAULT_WIDTHS = {ts: 256, pod: 160}.freeze

  def column_grid_attrs
    {
      controller: "logs-columns",
      logs_columns_storage_key_value: COLUMN_STORAGE_KEY,
      logs_columns_columns_value: COLUMN_KEYS.to_json,
      logs_columns_default_widths_value: COLUMN_DEFAULT_WIDTHS.to_json
    }
  end

  # loading_overlay — covers its `.la-cols-host` while the grid renders.
  # "Searching…" while a query is in flight (results table only — the frame
  # goes busy), "Rendering…" during the brief layout window before
  # logs-columns applies the template. CSS in theme.css picks which.
  def loading_overlay
    div(class: "la-results-loading absolute inset-0 z-20 flex items-center justify-center gap-2 bg-voodu-bg-2/70 backdrop-blur-[1px]") do
      render Components::UI::Spinner.new(color: "var(--voodu-accent)", size: 16, stroke: 3)
      span(class: "la-search-label text-[12px] font-medium text-voodu-text-2") { "Searching…" }
      span(class: "la-render-label text-[12px] font-medium text-voodu-text-2") { "Rendering…" }
    end
  end

  # column_header — the single sticky header row whose cells flow into the
  # `.log-list` grid so the labels track the data columns. TIME / POD carry a
  # resize handle; MESSAGE eats the 1fr and hosts `body_header_actions`.
  def column_header
    div(class: "log-row log-header") do
      column_header_cell("ts", "TIME", "log-h-ts", resizable: true)
      column_header_cell("pod", "POD", "log-h-pod", resizable: true)
      body_header_cell
    end
  end

  def column_header_cell(key, label, modifier, resizable:)
    span(class: "log-hcell #{modifier}", data: {logs_columns_target: "headerCell", column_key: key}) do
      span("aria-hidden": "true") { label }
      next unless resizable

      span(
        class: "log-col-resize",
        title: "Drag to resize",
        data: {action: "mousedown->logs-columns#startResize", column_key: key},
        "aria-hidden": "true"
      )
    end
  end

  def body_header_cell
    span(
      class: "log-hcell log-h-body flex items-center gap-3",
      data: {logs_columns_target: "headerCell", column_key: "body"}
    ) do
      span("aria-hidden": "true") { "MESSAGE" }
      span(class: "flex-1")
      body_header_actions
    end
  end

  # body_header_actions — trailing controls in the MESSAGE header cell.
  # Default: none (the modal). The results table overrides it with its toolbar.
  def body_header_actions
  end
end
