# frozen_string_literal: true

# Components::Metrics::TableCard — a dashboard panel (scope_kind "table")
# that renders a generic, schema-less data table from a DataSource
# (DataTable::Registry). Where ChartCard plots a series and NumberCard
# shows a count, this lists ROWS: the data_table Stimulus controller pulls
# pages from /metrics/datatable/:source/rows and renders them client-side
# (filter / sort / paging / pause / live-append are all client state).
#
# Toolbar (server-rendered from the source's field list): a column picker
# (select-all/clear), a field filter (field + value), and a pause toggle.
#
# Lives in the SAME metrics-display grid as the other cards (data-metric-key
# for hide/reorder/resize). NOT turbo-permanent — a permanent node fights
# the metrics-display reorder (Turbo re-inserts it out of place on a
# broadcast-tick frame reload). Instead the card re-renders normally (so
# applyOrder keeps it where the operator put it) and the data_table
# controller restores its rows + scroll from sessionStorage on reconnect,
# so the reload is seamless.
class Components::Metrics::TableCard < Components::Base
  def initialize(label:, color:, source:, scope:, name:, view:, rows_url:,
    fields: [], default_fields: [], filter_query: "", metric: nil, default_visible: true,
    row_action: nil, range: "1h", window_from: nil, window_until: nil)
    @label = label
    @color = color
    @source = source
    @scope = scope
    @name = name
    @view = view
    @rows_url = rows_url
    @fields = Array(fields)
    @default_fields = Array(default_fields)
    @filter_query = filter_query.to_s
    @metric = metric
    @default_visible = default_visible
    # row_action — optional per-row drill-down declared by the source
    # ({key:, event:, title:, icon:}). Renders a leading icon cell that
    # dispatches `datatable:rowaction` for a page host to act on.
    @row_action = row_action
    # range/window — the page's time picker, so the table honours the same
    # window as the charts (relative token, or the custom from/until span).
    @range = range.to_s
    @window_from = window_from
    @window_until = window_until
  end

  def view_template
    root_data = {}

    if @metric
      root_data[:metrics_display_target] = "card"
      root_data[:metric_key] = @metric
    end

    root_data[:default_visible] = "false" unless @default_visible

    div(
      id: dom_id,
      class: "relative bg-voodu-surface border border-voodu-border p-3.5 flex flex-col gap-2 min-w-0",
      data: root_data
    ) do
      card_header
      table_controller

      if @metric
        resize_handle("left")
        resize_handle("right")
      end
    end
  end

  private

  # dom_id — a stable per-panel id (the panel_key). Used to namespace the
  # data_table controller's sessionStorage state so a reconnect restores
  # the right table.
  def dom_id
    @metric ? "dt-#{@metric}" : nil
  end

  # row_action_icon_template — the drill-down icon, rendered once as a
  # <template> the data_table controller clones into each row's action
  # cell. A <template> ships SVG markup to JS without attribute-encoding it.
  def row_action_icon_template
    template(data: {data_table_target: "rowActionIcon"}) do
      render Icon.const_get(@row_action[:icon]).new(class: "w-3.5 h-3.5")
    end
  end

  def card_header
    div(class: "flex items-start justify-between gap-2 min-w-0") do
      span(
        class: "text-[11.5px] font-semibold uppercase tracking-[0.05em] min-w-0 truncate",
        style: "color: #{@color};"
      ) { @label }

      span(
        class: "inline-flex items-center px-1.5 h-[18px] text-[10.5px] font-medium rounded-voodu-sm " \
               "border border-voodu-border text-voodu-muted shrink-0 font-voodu-mono"
      ) { @view }
    end
  end

  # table_controller — the data_table Stimulus mount: toolbar + scroll
  # viewport. The viewport scrolls in BOTH axes (overflow-auto).
  def table_controller
    div(
      data: {
        controller: "data-table",
        data_table_url_value: @rows_url,
        data_table_source_value: @source,
        data_table_scope_value: @scope,
        data_table_name_value: @name,
        data_table_view_value: @view,
        data_table_key_value: @metric.to_s,
        data_table_range_value: @range,
        data_table_from_value: @window_from,
        data_table_until_value: @window_until,
        data_table_row_action_key_value: @row_action&.dig(:key),
        data_table_row_action_event_value: @row_action&.dig(:event),
        data_table_row_action_title_value: @row_action&.dig(:title)
      }.compact,
      class: "flex flex-col gap-2 min-w-0"
    ) do
      row_action_icon_template if @row_action
      toolbar
      div(
        data: {data_table_target: "viewport", action: "scroll->data-table#onScroll"},
        class: "relative overflow-auto max-h-[360px] border border-voodu-border bg-voodu-bg-2"
      ) do
        div(
          data: {data_table_target: "status"},
          class: "px-3 py-6 text-center text-[12px] text-voodu-muted"
        ) { "Loading…" }
      end
    end
  end

  def toolbar
    div(class: "flex items-center gap-1.5 flex-wrap") do
      columns_picker
      query_input
      refresh_button
      live_toggle
    end
  end

  # columns_picker — a dropdown of checkboxes (one per field) with a
  # select-all/clear toggle. Defaults checked = the source's default_fields.
  def columns_picker
    div(class: "relative", data: {controller: "dropdown"}) do
      button(
        type: "button",
        data: {action: "click->dropdown#toggle"},
        class: "inline-flex items-center gap-1 px-2 h-7 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[11.5px] hover:bg-voodu-surface-2"
      ) do
        render Icon::AdjustmentsHorizontalOutline.new(class: "w-3.5 h-3.5")
        span { "Columns" }
      end

      div(
        hidden: true,
        data: {dropdown_target: "menu"},
        class: "absolute left-0 top-[calc(100%+4px)] z-30 min-w-[180px] max-h-[300px] overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface shadow-2xl"
      ) do
        div(class: "flex items-center justify-between px-2.5 py-1.5 border-b border-voodu-border") do
          span(class: "text-[10.5px] uppercase tracking-[0.05em] text-voodu-muted-2") { "Columns" }
          button(
            type: "button",
            data: {action: "click->data-table#toggleAllColumns"},
            class: "text-[11px] text-voodu-accent-2 hover:underline"
          ) { "Select all / clear" }
        end

        @fields.each { |field| column_option(field) }
      end
    end
  end

  def column_option(field)
    label(class: "flex items-center gap-2 px-2.5 py-1.5 cursor-pointer hover:bg-voodu-hover") do
      input(
        type: "checkbox",
        value: field,
        checked: @default_fields.include?(field),
        data: {data_table_target: "colToggle", action: "change->data-table#applyColumns"},
        class: "w-3.5 h-3.5 shrink-0 cursor-pointer",
        style: "accent-color: var(--voodu-accent);"
      )
      span(class: "text-[12px] font-voodu-mono text-voodu-text") { field }
    end
  end

  # query_input — the runtime filter, the same DSL as the panel config +
  # /logs Analytics: `@to_user like /5511/`, `and`/`or`/`not`. Seeded with
  # the panel's config filter; edits re-fetch (debounced in the controller).
  def query_input
    input(
      type: "text",
      value: @filter_query,
      placeholder: "filter — e.g. @to_user like /5511/",
      autocomplete: "off",
      spellcheck: "false",
      data: {data_table_target: "query", action: "input->data-table#applyFilter"},
      class: "flex-1 min-w-[160px] h-7 px-2 border border-voodu-border bg-voodu-surface text-voodu-text text-[11.5px] font-voodu-mono placeholder:text-voodu-muted-2 focus:outline-none focus:border-voodu-accent-line"
    )
  end

  # refresh_button — pull the latest page on demand. The table is a static
  # snapshot by default (no auto-reorder); refresh is how you catch up
  # without turning on live streaming.
  def refresh_button
    button(
      type: "button",
      data: {action: "click->data-table#refresh"},
      title: "Refresh",
      "aria-label": "Refresh",
      class: "inline-flex items-center justify-center w-7 h-7 border border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2 ml-auto"
    ) { render Icon::ArrowPathOutline.new(class: "w-3.5 h-3.5") }
  end

  # live_toggle — opt IN to live-append (off by default so the table never
  # reorders under you while reading). On: new rows stream in at the top
  # (scroll position is preserved when you're reading below the fold).
  def live_toggle
    button(
      type: "button",
      data: {data_table_target: "live", action: "click->data-table#toggleLive"},
      title: "Live updates",
      "aria-label": "Toggle live updates",
      class: "inline-flex items-center gap-1.5 px-2 h-7 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[11.5px] hover:bg-voodu-surface-2"
    ) do
      span(data: {data_table_target: "liveDot"}, class: "inline-block w-2 h-2 rounded-full bg-voodu-muted-2")
      span { "Live" }
    end
  end

  def resize_handle(edge)
    div(
      data: {action: "pointerdown->metrics-display#startResize", resize_edge: edge},
      aria: {hidden: "true"},
      title: "Drag to resize",
      class: tokens(
        "absolute top-0 bottom-0 w-1.5 cursor-col-resize hover:bg-voodu-accent/30 active:bg-voodu-accent/60 z-10 touch-none",
        (edge == "left") ? "left-0" : "right-0"
      )
    )
  end
end
