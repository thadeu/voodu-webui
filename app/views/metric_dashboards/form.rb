# frozen_string_literal: true

# Views::MetricDashboards::Form — the dashboard builder. Reached two
# ways: swapped into the switcher drawer's turbo_frame (embed: true,
# New/Edit), or rendered full-page with chrome (embed: false) when a
# create/update validation error needs to be shown standalone.
#
# The panel picker is driven by dashboard_builder_controller.js: a
# source <select> (Host + each pod workload) + a metric <select>
# (filtered by the source's kind from the metric catalog) + an Add
# button that appends chips to an in-memory list serialized into a
# hidden `metric_dashboard[panels]` JSON field on submit.
class Views::MetricDashboards::Form < Views::Base
  # The editor lives in the manage modal's right turbo-frame. Selecting a rail
  # item / New swaps THIS frame; the controller's 422 re-render targets it too.
  FRAME_ID = "dashboard-editor"

  # Accent palette offered for log-count panels. A count has no canonical
  # per-metric color (it isn't CPU/Memory/…), so the operator picks one.
  # Drawn from the chart palette tokens; red stays available for "errors"
  # counts (a 5xx / 480-Cancel filter).
  LOG_COLORS = %w[
    var(--voodu-orange) var(--voodu-amber) var(--voodu-green)
    var(--voodu-blue) var(--voodu-purple) var(--voodu-pink)
    var(--voodu-teal) var(--voodu-red)
  ].freeze

  # Palette offered for METRIC panels. Each metric ships a canonical color
  # (CPU purple, Memory blue, …) which is the default; this lets the operator
  # override it. Covers every canonical chart token so the default always
  # lands on a swatch.
  METRIC_COLORS = %w[
    var(--voodu-purple) var(--voodu-blue) var(--voodu-teal) var(--voodu-green)
    var(--voodu-indigo) var(--voodu-cyan) var(--voodu-orange) var(--voodu-amber)
    var(--voodu-pink) var(--voodu-red)
  ].freeze

  def initialize(server:, dashboard:, server_pods: nil, embed: true,
    current_path: nil, servers: [], current_server: nil,
    return_to: nil)
    @server = server
    @dashboard = dashboard
    # server_pods — [[server, [compact pods]], …] for EVERY server in the org
    # (M2). Every source / log / table / hep3 option enumerates across ALL of
    # them and carries its server_id, so a panel can read from any server. Falls
    # back to the single default server for a lone-server org / legacy caller.
    @server_pods = Array(server_pods).presence || [[server, []]]
    @embed = embed
    @current_path = current_path
    @servers = servers
    @current_server = current_server
    @return_to = return_to
  end

  # servers_json — { server_id => name } for every org server. The builder uses
  # it to prefix a re-edited panel's source label with the right server.
  def servers_json
    @server_pods.to_h { |server, _| [server.id.to_s, server.name.to_s] }.to_json
  end

  def view_template
    if @embed
      builder_panel
    else
      render Components::Layouts::Dashboard.new(
        current_path: @current_path, servers: @servers, current_server: @current_server,
        breadcrumb: overview_crumbs({label: "Metrics"})
      ) do
        div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 max-w-[720px]") { builder_panel }
      end
    end
  end

  private

  def builder_panel
    turbo_frame_tag(FRAME_ID, class: "flex flex-col flex-1 min-h-0") do
      # data-dashboard-uuid → the dashboard-rail controller reads this on
      # turbo:frame-load to move its active highlight to the matching rail
      # item. "new" matches nothing → rail goes to empty-selection state.
      # flex-1 min-h-0 → carries the modal-body height down to the editor
      # columns so the Panels sidebar can run full-height.
      div(class: "flex flex-col flex-1 min-h-0", data: {dashboard_uuid: @dashboard.persisted? ? @dashboard.uuid : "new"}) do
        builder_form
      end
    end
  end

  # pin_toggle — POST to pin/unpin: at most one pinned dashboard is the
  # /metrics default. An anchor with data-turbo-method (NOT a nested
  # <form> — that would be invalid HTML inside the builder form); _top so
  # the redirect navigates the whole page. Sits on the title row next to
  # the name input.
  def pin_toggle
    pinned = @dashboard.pinned
    action = pinned ? unpin_metric_dashboard_path(@dashboard) : pin_metric_dashboard_path(@dashboard)
    title = pinned ? "Unpin — /metrics stops defaulting here" : "Pin — open /metrics here by default"

    a(
      href: action,
      title: title, "aria-label": title,
      data: {turbo_method: :post, turbo_frame: "_top"},
      class: tokens(
        "inline-flex items-center justify-center w-9 h-9 shrink-0 border",
        pinned ? "border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2" : "border-voodu-border bg-voodu-surface text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2"
      )
    ) { render((pinned ? Icon::BookmarkSolid : Icon::BookmarkOutline).new(class: "w-4 h-4")) }
  end

  def error_banner
    div(class: "px-3 py-2 border border-voodu-red/40 bg-voodu-red-dim text-voodu-red text-[12px]") do
      @dashboard.errors.full_messages.each { |m| div { m } }
    end
  end

  def builder_form
    form(
      action: form_action,
      method: "post",
      # turbo_frame: "_top" — the form lives inside the drawer's
      # "dashboards-panel" turbo_frame. data-turbo:false is NOT honored
      # for a submit inside a frame (Turbo treats it as a frame request
      # and 404s the missing frame on the redirect → "Content missing").
      # "_top" makes the submit navigate the whole page: success
      # redirects to the rendered dashboard, a 422 renders the full-page
      # builder (embed: false) with inline errors.
      data: {
        turbo_frame: "_top",
        controller: "dashboard-builder",
        dashboard_builder_catalog_value: catalog_json,
        dashboard_builder_logs_source_views_value: logs_source_views.to_json,
        dashboard_builder_hep3_source_views_value: hep3_source_views.to_json,
        dashboard_builder_logs_fields_value: DataTable::LogsSource::FIELDS.to_json,
        dashboard_builder_hep3_fields_value: hep3_filter_fields.to_json,
        dashboard_builder_hep3_hints_value: TABLE_FILTER_HINTS.to_json,
        dashboard_builder_http_test_url_value: metrics_datatable_http_test_path,
        dashboard_builder_preview_url_value: metrics_preview_panel_path,
        # default_server — the server a fresh (host) panel binds to before the
        # operator picks a source. current_server, so single-server behaviour is
        # unchanged; a picked source overrides it with its own server_id.
        dashboard_builder_default_server_value: @server&.id.to_s,
        # servers — { server_id => name } for every org server, so re-editing a
        # saved panel can label its source trigger with the right server prefix.
        dashboard_builder_servers_value: servers_json,
        dashboard_builder_panels_value: existing_panels_json,
        # DS confirm before saving (the singleton confirm-host swaps the
        # native dialog). Submit → confirm → save → reopens the modal.
        turbo_confirm: @dashboard.persisted? ? "Save changes to this dashboard?" : "Create this dashboard?"
      },
      # No padding here — the columns run edge-to-edge so the Panels
      # sidebar is a true flush second sidebar (bg + border-r). The
      # breathing room lives on the CONTENT column only (see content_pane).
      class: "flex flex-col flex-1 min-h-0"
    ) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch") if @dashboard.persisted?
      # return_to — the /metrics URL the operator opened the builder from
      # (often a multi-dashboard ?pid=a,b view). Carried through so a
      # save lands them back on the exact view they were on, not the
      # single edited dashboard.
      input(type: "hidden", name: "return_to", value: @return_to) if @return_to.present?

      editor_split
      hidden_panels_input
    end
  end

  # name_header — the dashboard NAME as the editor title, but rendered as a
  # clearly-editable field: a persistent border + a pencil affordance on the
  # right (so it doesn't read as static text), focusing to the accent border.
  # Pin + delete sit to its right.
  def name_header
    div(class: "flex items-center gap-2 shrink-0") do
      div(class: "flex-1 min-w-0 relative") do
        input(
          type: "text",
          name: "metric_dashboard[name]",
          value: @dashboard.name,
          placeholder: "Untitled dashboard",
          autocomplete: "off",
          "aria-label": "Dashboard name",
          class: "w-full bg-voodu-surface border border-voodu-border text-[16px] font-semibold text-voodu-text " \
                 "placeholder:text-voodu-muted-2 pl-3 pr-9 py-2 hover:border-voodu-border-2 " \
                 "focus:border-voodu-accent-line focus:bg-voodu-surface-2 focus:outline-none transition-colors"
        )
        span(class: "absolute right-3 top-1/2 -translate-y-1/2 text-voodu-muted-2 pointer-events-none") do
          render Icon::PencilSquareOutline.new(class: "w-4 h-4")
        end
      end

      if @dashboard.persisted?
        pin_toggle
        delete_button
      end
    end
  end

  # editor_split — the editor's two columns nested right of the modal's
  # dashboards rail, giving the full surface a [dashboards][panels][form]
  # read: a standalone Panels sidebar + the content pane (title row +
  # detail editor). items-stretch so the panels sidebar's surface fills
  # the column height. Stacks on mobile, side-by-side at vmd+.
  def editor_split
    div(class: "flex flex-col vmd:flex-row vmd:items-stretch flex-1 min-h-0") do
      panels_sidebar
      content_pane
    end
  end

  # content_pane — the 3rd column: the dashboard's title row (name + pin +
  # delete) over the panel detail editor. The title moved IN here from a
  # full-width header, so it aligns with the form content rather than
  # spanning over the panels sidebar. The detail editor scrolls inside (the
  # title row stays put) when a config block is taller than the column.
  # content_pane — the form column. ALL the editor padding lives here (the
  # panels sidebar + dashboards rail stay flush), so the surface reads as
  # [rail][panels][padded form].
  def content_pane
    div(class: "flex-1 min-w-0 flex flex-col gap-3 min-h-0 p-4") do
      error_banner if @dashboard.errors.any?
      name_header
      detail_pane
      footer_actions
    end
  end

  # panels_sidebar — the middle column: a STANDALONE panel (surface-3, a
  # touch lighter than the dashboards rail's surface, with its own border)
  # holding "Add panel" + the draggable panel list (rendered by
  # dashboard_builder_controller, each row selects → content pane).
  def panels_sidebar
    div(class: "vmd:w-[230px] shrink-0 flex flex-col gap-2 p-3 bg-voodu-surface-side border-b vmd:border-b-0 vmd:border-r border-voodu-border min-h-0 overflow-hidden") do
      # Thin header + square "+" (tooltip "Add panel"), mirroring the
      # dashboards rail — no full-width green button eating vertical space.
      div(class: "flex items-center justify-between gap-2 shrink-0") do
        span(class: "text-[11px] font-medium text-voodu-text-2 uppercase tracking-[0.06em]") { "Panels" }
        button(
          type: "button",
          data: {action: "click->dashboard-builder#newPanel", tooltip: "Add panel"},
          "aria-label": "Add panel",
          class: "inline-flex items-center justify-center w-7 h-7 shrink-0 border border-voodu-border bg-voodu-surface text-voodu-muted " \
                 "hover:border-voodu-accent-line hover:bg-voodu-accent-dim hover:text-voodu-accent-2 transition-colors"
        ) { render Icon::PlusOutline.new(class: "w-4 h-4") }
      end

      # The list scrolls inside the (full-height) sidebar when it outgrows
      # the column; the header stays pinned above.
      div(data: {dashboard_builder_target: "list"}, class: "flex flex-col gap-1.5 flex-1 min-h-0 overflow-auto scrollbar-hidden")
      div(data: {dashboard_builder_target: "empty"}, class: "text-[11.5px] text-voodu-muted px-1 py-1 shrink-0") do
        "No panels yet — + to start."
      end
    end
  end

  # detail_pane — four mutually-exclusive states the builder controller toggles:
  #   idleStep    — neutral placeholder (default on open: nothing selected)
  #   typeStep    — the "Add panel" type chooser (Metric / Log count)
  #   metricBlock — metric panel config (new or editing a selected row)
  #   logBlock    — log-count config (new or editing a selected row)
  # Opening a dashboard lands on idleStep; the type chooser only appears via
  # "Add panel", so editing no longer reads as adding.
  def detail_pane
    div(class: "flex-1 min-w-0 min-h-0 overflow-auto flex flex-col") do
      idle_placeholder
      type_step_cards
      add_panel_row
      add_log_panel_row
      add_table_panel_row
      add_http_panel_row
      panel_preview_pane
    end
  end

  # panel_preview_pane — a live preview of the panel being configured, in the
  # empty space below the config. Manual (a refresh-icon button, not live) so it
  # never auto-fires an external HTTP request; the controller POSTs the current
  # panel to /metrics/previews/panel and swaps the rendered card in. Shown only
  # in the config step (the controller toggles it in syncWizard).
  def panel_preview_pane
    div(hidden: true, data: {dashboard_builder_target: "previewPane"}, class: "flex flex-col gap-2 mt-4 pt-4 border-t border-voodu-border-2") do
      div(class: "flex items-center justify-between gap-2") do
        span(class: "text-[11.5px] font-medium text-voodu-text-2 uppercase tracking-[0.04em]") { "Preview" }
        button(
          type: "button",
          title: "Refresh preview",
          "aria-label": "Refresh preview",
          data: {action: "click->dashboard-builder#refreshPreview", dashboard_builder_target: "previewRefresh"},
          class: "inline-flex items-center justify-center w-7 h-7 border border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2"
        ) { render Icon::ArrowPathOutline.new(class: "w-3.5 h-3.5") }
      end

      div(data: {dashboard_builder_target: "panelPreview"}) { preview_placeholder }
    end
  end

  def preview_placeholder
    div(class: "flex items-center justify-center h-[180px] border border-voodu-border border-dashed text-[12px] text-voodu-muted text-center px-4") do
      plain "Refresh to preview the panel"
    end
  end

  # idle_placeholder — the resting state of the detail pane: a muted prompt
  # to select a panel or add one. Replaces the type chooser as the default,
  # so an edit session doesn't open looking like an add session.
  def idle_placeholder
    div(
      data: {dashboard_builder_target: "idleStep"},
      class: "flex flex-col items-center justify-center text-center gap-1.5 h-full min-h-[220px] border border-dashed border-voodu-border-2 px-6 py-10"
    ) do
      render Icon::Squares2x2Outline.new(class: "w-6 h-6 text-voodu-muted-2")
      span(class: "text-[12.5px] text-voodu-text-2") { "Select a panel to edit" }
      span(class: "text-[11.5px] text-voodu-muted") { "or add a new one with + Add panel" }
    end
  end

  # type_step_cards — step 1 of the add wizard: pick the panel TYPE with two
  # big cards (each with an SVG skeleton of what it renders). Replaces the old
  # segmented Metric|Log tab, which read as ambiguous. Choosing a card hides
  # this step and reveals that type's config block (step 2); a "Change type"
  # link there returns here.
  def type_step_cards
    # hidden by default — the detail pane opens on idleStep; the controller
    # reveals this only when "Add panel" is clicked (prevents a pre-JS flash
    # of both idle + chooser).
    div(hidden: true, data: {dashboard_builder_target: "typeStep"}, class: "flex flex-col gap-2") do
      span(class: "text-[11.5px] font-medium text-voodu-text-2 uppercase tracking-[0.04em]") { "Choose panel type" }

      div(class: "flex flex-wrap gap-3") do
        type_card("metric", "Metric", "CPU, memory, log queries — chart, gauge or number") { metric_preview_svg }
        type_card("hep3", "HEP3", "SIP capture — Messages, Calls, Errors — filter, sort, live") { table_preview_svg } if hep3_readers.any?
        type_card("http", "HTTP / external API", "Fetch JSON from any URL — table or chart") { metric_preview_svg }
      end
    end
  end

  # type_card — near-square pick card: a tall chart-preview area up top
  # (full-bleed, so the skeleton reads at a glance) over a compact
  # title + description. Fixed ~220px wide (max-w-full so it shrinks on
  # mobile) and wraps instead of stretching across the wide modal.
  def type_card(value, title, desc)
    button(
      type: "button",
      data: {action: "click->dashboard-builder#chooseType", add_type: value},
      class: "flex flex-col w-[220px] max-w-full overflow-hidden border border-voodu-border-2 bg-voodu-surface text-left hover:border-voodu-accent-line hover:bg-voodu-surface-2 transition-colors"
    ) do
      div(class: "h-[120px] w-full flex items-center justify-center px-4 py-3 border-b border-voodu-border-2 bg-voodu-surface-2/40") { yield }
      div(class: "flex flex-col gap-1 p-3") do
        span(class: "block text-[13px] font-medium text-voodu-text") { title }
        span(class: "block text-[11.5px] text-voodu-muted leading-snug") { desc }
      end
    end
  end

  # metric_preview_svg — a big area chart skeleton (CPU purple) that fills
  # the card's preview area.
  def metric_preview_svg
    svg(viewBox: "0 0 200 100", class: "w-full h-full", fill: "none", "aria-hidden": "true", preserveAspectRatio: "xMidYMid meet") do |s|
      s.polygon(points: "0,72 33,52 66,62 100,28 133,42 166,16 200,33 200,100 0,100", fill: "var(--voodu-purple)", opacity: "0.18")
      s.polyline(points: "0,72 33,52 66,62 100,28 133,42 166,16 200,33", stroke: "var(--voodu-purple)", "stroke-width": "3", "stroke-linejoin": "round", "stroke-linecap": "round")
    end
  end

  # log_preview_svg — a big-number + sparkline skeleton (orange) that fills
  # the card's preview area.
  def log_preview_svg
    svg(viewBox: "0 0 200 100", class: "w-full h-full", fill: "none", "aria-hidden": "true", preserveAspectRatio: "xMidYMid meet") do |s|
      s.text(x: "100", y: "50", "text-anchor": "middle", "font-size": "40", "font-weight": "700", fill: "var(--voodu-text)", "font-family": "var(--voodu-font-mono, monospace)") { "1,284" }
      s.polyline(points: "40,82 80,74 120,80 160,68", stroke: "var(--voodu-orange)", "stroke-width": "3", "stroke-linecap": "round", "stroke-linejoin": "round")
    end
  end

  # table_preview_svg — a rows-and-columns skeleton (teal accent) for the
  # Table panel type card.
  def table_preview_svg
    svg(viewBox: "0 0 200 100", class: "w-full h-full", fill: "none", "aria-hidden": "true", preserveAspectRatio: "xMidYMid meet") do |s|
      s.rect(x: "20", y: "18", width: "160", height: "16", fill: "var(--voodu-teal)", opacity: "0.25")
      [40, 58, 76].each do |y|
        s.rect(x: "20", y: y.to_s, width: "160", height: "12", fill: "var(--voodu-border-2)", opacity: "0.5")
      end
      [66, 112].each do |x|
        s.line(x1: x.to_s, y1: "18", x2: x.to_s, y2: "88", stroke: "var(--voodu-border-2)", "stroke-width": "1.5")
      end
    end
  end

  # add_table_panel_row — the Table panel builder. Row 1 (mirrors the log
  # block: pod narrow, label wide): the reader POD, a LABEL, and the
  # combined SOURCE·VIEW dropdown (HEP3 — Messages / Calls / Errors). Row 2
  # is an optional pre-filter (field + value) so the panel opens already
  # filtered — same idea as the log block's query. Then the accent color.
  # No Add button: edits auto-save (dashboard-builder#autoCommit).
  def add_table_panel_row
    div(hidden: true, data: {dashboard_builder_target: "tableBlock"}, class: "flex flex-col gap-2.5 p-3 border border-voodu-border-2 bg-voodu-surface") do
      div(class: "flex items-center justify-between gap-2") do
        span(
          data: {dashboard_builder_target: "tableBlockTitle"},
          class: "text-[11.5px] font-medium text-voodu-text-2 uppercase tracking-[0.04em]"
        ) { "Table panel" }
        change_type_link
      end
      span(class: "text-[11px] text-voodu-muted leading-relaxed") do
        "Live rows from the chosen data source. Columns are chosen on the panel itself."
      end

      div(class: "flex flex-col vmd:flex-row gap-2") do
        table_label_input
        table_source_view_picker
      end

      hep3_shape_chips
      hep3_percent_toggle
      table_filter_editor
      table_color_swatches
    end
  end

  # add_http_panel_row — the external-API panel builder. Request config up top
  # (method + URL, headers, body, interval), then Table/Chart, then the JSON
  # mapping (the json-editor — same code shell as the query editor), then the
  # Test loop (raw response × parsed output). Functional MVP; polish later.
  # add_http_panel_row — the external-API panel builder, Postman-shaped: a
  # panel-identity row (label + visualization + accent), a URL bar (method +
  # URL + Test), request tabs (Mapping / Headers / Body), and the response ×
  # parsed split. The mapping is the star, so its tab opens active.
  def add_http_panel_row
    div(hidden: true, data: {dashboard_builder_target: "httpBlock"}, class: "flex flex-col gap-3 p-3 border border-voodu-border-2 bg-voodu-surface") do
      div(class: "flex items-center justify-between gap-2") do
        span(data: {dashboard_builder_target: "httpBlockTitle"}, class: "text-[11.5px] font-medium text-voodu-text-2 uppercase tracking-[0.04em]") { "HTTP panel" }
        change_type_link
      end

      http_identity_row
      http_viz_chips
      http_url_bar
      http_tabs
      http_tab_panels
      http_test_result
      http_color_footer
    end
  end

  # http_identity_row — just the panel label. The interval isn't a per-panel
  # field: the request follows the page's active range/interval (the source
  # resolves the outbound window from it). Styled like every other panel's label
  # field (h-9, prose font) — NOT the mono URL-bar input — so it matches the
  # table/log/hep3 forms.
  def http_identity_row
    input(
      type: "text", placeholder: "Panel label — e.g. Active calls",
      autocomplete: "off", spellcheck: "false",
      data: {dashboard_builder_target: "httpLabel", action: "input->dashboard-builder#autoCommit"},
      class: "w-full h-9 px-2.5 border border-voodu-border bg-voodu-surface text-voodu-text text-[12.5px] " \
             "placeholder:text-voodu-muted-2 focus:outline-none focus:border-voodu-accent-line"
    )
  end

  # http_viz_chips — the visualization picker as preview cards (Table / Area /
  # Number), same idiom as the HEP3 shape chips + the panel-type chooser.
  def http_viz_chips
    div(class: "flex flex-wrap gap-2.5") do
      http_viz_chip("table", "Table") { table_preview_svg }
      http_viz_chip("area", "Area") { render Components::Metrics::ChartShape.new(type: "area") }
      http_viz_chip("bars", "Bar") { render Components::Metrics::ChartShape.new(type: "bars") }
      http_viz_chip("line", "Line") { render Components::Metrics::ChartShape.new(type: "line") }
      http_viz_chip("number", "Number") { log_preview_svg }
    end
  end

  def http_viz_chip(value, text)
    button(
      type: "button",
      data: {dashboard_builder_target: "httpChartChip", chart_type: value, action: "click->dashboard-builder#selectHttpChartType"},
      class: "flex flex-col w-[110px] max-w-full overflow-hidden border border-voodu-border-2 bg-voodu-surface text-left transition-colors " \
             "hover:border-voodu-accent-line hover:bg-voodu-surface-2 text-voodu-muted " \
             "data-[active=true]:border-voodu-accent-line data-[active=true]:text-voodu-accent-2"
    ) do
      div(class: "h-[52px] w-full flex items-center justify-center px-3 py-2 border-b border-voodu-border-2 bg-voodu-surface-2/40") { yield }
      span(class: "block text-[12px] font-medium text-voodu-text px-2.5 py-1.5") { text }
    end
  end

  # http_url_bar — the request line: method (our dropdown) + URL + Test.
  def http_url_bar
    div(class: "flex items-stretch gap-0 border border-voodu-border bg-voodu-bg-2") do
      http_method_dropdown
      http_input("httpUrl", "https://api.example.com/todos", flex: true, bare: true)
      button(
        type: "button",
        data: {action: "click->dashboard-builder#testHttp"},
        class: "shrink-0 inline-flex items-center px-3 text-[12px] font-medium border-l border-voodu-border bg-voodu-surface-2 text-voodu-accent-2 hover:bg-voodu-accent-dim"
      ) { "Test" }
    end
  end

  # http_method_dropdown — the HTTP verb via our dropdown (not a native select).
  # A hidden input carries the value (httpMethod target); the label shows it.
  HTTP_METHODS = %w[GET POST PUT PATCH DELETE HEAD OPTIONS].freeze

  def http_method_dropdown
    div(class: "relative shrink-0 border-r border-voodu-border", data: {controller: "dropdown"}) do
      input(type: "hidden", value: "GET", data: {dashboard_builder_target: "httpMethod"})
      button(
        type: "button",
        data: {action: "click->dropdown#toggle"},
        class: "inline-flex items-center gap-1.5 h-8 px-2.5 bg-voodu-surface-2 text-voodu-text-2 text-[12px] font-voodu-mono font-medium hover:bg-voodu-surface"
      ) do
        span(data: {dashboard_builder_target: "httpMethodLabel"}) { "GET" }
        render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 opacity-70")
      end
      div(
        hidden: true,
        data: {dropdown_target: "menu"},
        class: "absolute left-0 top-[calc(100%+4px)] z-40 min-w-[120px] border border-voodu-border-2 bg-voodu-surface shadow-2xl"
      ) do
        HTTP_METHODS.each do |m|
          button(
            type: "button",
            data: {method: m, action: "click->dashboard-builder#selectHttpMethod click->dropdown#close"},
            class: "flex w-full items-center px-3 py-1.5 text-left text-[12px] font-voodu-mono text-voodu-text hover:bg-voodu-hover"
          ) { m }
        end
      end
    end
  end

  def http_color_footer
    div(class: "flex items-center gap-2 pt-2.5 border-t border-voodu-border") do
      span(class: "text-[10px] uppercase tracking-[0.06em] text-voodu-muted-2") { "Accent" }
      http_color_swatches
    end
  end

  def http_tabs
    div(class: "flex items-center gap-4 border-b border-voodu-border") do
      [%w[mapping Mapping], %w[headers Headers], %w[body Body]].each_with_index do |(name, text), i|
        button(
          type: "button",
          data: {dashboard_builder_target: "httpTab", http_tab: name, action: "click->dashboard-builder#switchHttpTab"},
          "aria-selected": (i.zero? ? "true" : "false"),
          class: "pb-1.5 -mb-px text-[12px] border-b-2 border-transparent text-voodu-muted hover:text-voodu-text " \
                 "aria-selected:border-voodu-accent-line aria-selected:text-voodu-text"
        ) { text }
      end
    end
  end

  def http_tab_panels
    div do
      div(data: {dashboard_builder_target: "httpTabPanel", http_tab: "mapping"}) { http_mapping_editor }
      div(hidden: true, data: {dashboard_builder_target: "httpTabPanel", http_tab: "headers"}) { http_headers_editor }
      div(hidden: true, data: {dashboard_builder_target: "httpTabPanel", http_tab: "body"}) { http_body_editor }
    end
  end

  def http_input(target, placeholder, flex: false, bare: false, width: nil)
    base = "h-8 px-2 text-voodu-text text-[12px] font-voodu-mono placeholder:text-voodu-muted-2 focus:outline-none"
    chrome = bare ? "bg-transparent border-0 focus:ring-0" : "border border-voodu-border bg-voodu-surface focus:border-voodu-accent-line"
    input(
      type: "text", placeholder: placeholder, autocomplete: "off", spellcheck: "false",
      data: {dashboard_builder_target: target, action: "input->dashboard-builder#autoCommit"},
      class: tokens(base, chrome, (flex ? "flex-1 min-w-0" : nil), width)
    )
  end

  # http_headers_editor — add-row key/value pairs (Postman-style), plus a
  # <template> row the controller clones for "+ Add". Each row's key/value are
  # httpHeaderKey/httpHeaderValue targets; buildHttpPanel zips them into a hash.
  def http_headers_editor
    div(class: "flex flex-col gap-1.5 pt-2") do
      div(data: {dashboard_builder_target: "httpHeadersRows"}, class: "flex flex-col gap-1.5") { http_header_row }
      template(data: {dashboard_builder_target: "httpHeaderTemplate"}) { http_header_row }
      button(
        type: "button",
        data: {action: "click->dashboard-builder#addHttpHeader"},
        class: "self-start inline-flex items-center gap-1 px-2 h-6 text-[11px] border border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2"
      ) { "+ Add header" }
    end
  end

  def http_header_row
    div(class: "flex items-center gap-1.5") do
      input(
        type: "text", placeholder: "Key", autocomplete: "off", spellcheck: "false",
        data: {dashboard_builder_target: "httpHeaderKey", action: "input->dashboard-builder#autoCommit"},
        class: "w-1/3 h-7 px-2 border border-voodu-border bg-voodu-surface text-voodu-text text-[12px] font-voodu-mono placeholder:text-voodu-muted-2 focus:outline-none focus:border-voodu-accent-line"
      )
      input(
        type: "text", placeholder: "Value", autocomplete: "off", spellcheck: "false",
        data: {dashboard_builder_target: "httpHeaderValue", action: "input->dashboard-builder#autoCommit"},
        class: "flex-1 min-w-0 h-7 px-2 border border-voodu-border bg-voodu-surface text-voodu-text text-[12px] font-voodu-mono placeholder:text-voodu-muted-2 focus:outline-none focus:border-voodu-accent-line"
      )
      button(
        type: "button", "aria-label": "Remove header",
        data: {action: "click->dashboard-builder#removeHttpHeader"},
        class: "shrink-0 inline-flex items-center justify-center w-7 h-7 border border-voodu-border bg-voodu-surface text-voodu-muted hover:text-voodu-red"
      ) { "×" }
    end
  end

  def http_body_editor
    div(class: "flex flex-col gap-1 pt-2") do
      http_json_editor("httpBody", 'Body — raw JSON, e.g. { "name": "cpf" }')
    end
  end

  # http_mapping_editor — the JSON mapping via the shared json-editor, with a
  # `?` popover cheatsheet (same idiom as the QueryEditor's Syntax help).
  def http_mapping_editor
    div(class: "flex flex-col gap-1.5 pt-2") do
      http_json_editor("httpMapping", '{ "root": "series", "ts": "t", "value": "v" }')
      http_mapping_help
    end
  end

  # http_mapping_help — a peek-and-dismiss popover documenting the mapping
  # shapes; portaled to the dialog by the popover controller (escapes the
  # modal's overflow), mirroring the query editor's Syntax reference.
  def http_mapping_help
    div(class: "relative self-start", data: {controller: "popover"}) do
      button(
        type: "button",
        "aria-label": "Mapping reference",
        data: {action: "click->popover#toggle", popover_target: "trigger", tooltip: "Mapping help"},
        class: "inline-flex items-center gap-1 text-[11.5px] text-voodu-text-2 hover:text-voodu-text"
      ) do
        render Icon::QuestionMarkCircleOutline.new(class: "w-3.5 h-3.5")
        span { "Mapping" }
      end

      div(
        hidden: true,
        data: {popover_target: "menu"},
        class: "w-[380px] max-w-[calc(100vw-32px)] border border-voodu-border-2 bg-voodu-surface shadow-2xl p-3.5 flex flex-col gap-2 text-[11.5px] text-voodu-muted leading-relaxed"
      ) do
        http_help_line("root", "path to the array in the response (blank = the response IS the array)")
        http_help_line("path", "dot path into each item — e.g. data.user.name or items[0].id")
        div(class: "pt-1.5 border-t border-voodu-border flex flex-col gap-1.5") do
          http_help_block("Table", '{ "root": "items", "columns": [{ "field": "name", "path": "name" }] }')
          http_help_block("Chart", '{ "root": "series", "ts": "t", "value": "v" }')
        end
        div(class: "pt-1.5 border-t border-voodu-border text-voodu-muted-2") do
          plain "The active range, interval, scope and label ride the request as query params."
        end
      end
    end
  end

  def http_help_line(label, note)
    div(class: "flex items-baseline gap-2") do
      code(class: "font-voodu-mono text-voodu-text-2 shrink-0") { label }
      span { note }
    end
  end

  def http_help_block(label, example)
    div(class: "flex flex-col gap-0.5") do
      span(class: "text-[10px] uppercase tracking-[0.06em] text-voodu-muted-2") { label }
      code(class: "font-voodu-mono text-[11px] text-voodu-text-2 break-all") { example }
    end
  end

  # http_json_editor — the shared code editor shell (gutter line numbers +
  # highlight + Format), the SAME json-editor the alerts destination form uses.
  # The textarea doubles as `target` (dashboard-builder) so its value drives
  # autoCommit + the Test.
  def http_json_editor(target, placeholder)
    div(class: "voodu-code relative overflow-hidden resize-y border border-voodu-border bg-voodu-surface min-h-[150px]", data: {controller: "json-editor"}) do
      pre(class: "voodu-code__hl", "aria-hidden": "true", data: {json_editor_target: "highlight"})
      div(class: "voodu-code__gutter", "aria-hidden": "true", data: {json_editor_target: "gutter"})
      textarea(
        rows: "7", spellcheck: "false", autocapitalize: "off", autocomplete: "off",
        placeholder: placeholder,
        class: "voodu-code__input",
        data: {
          json_editor_target: "input",
          dashboard_builder_target: target,
          action: "input->json-editor#render input->dashboard-builder#autoCommit keydown->json-editor#keydown"
        }
      ) { "" }
      button(
        type: "button", title: "Format JSON",
        data: {action: "click->json-editor#format"},
        class: "absolute top-1.5 right-1.5 z-10 inline-flex items-center gap-1 px-1.5 h-5 text-[10px] font-medium " \
               "border border-voodu-border-2 bg-voodu-surface-2 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface"
      ) { "Format" }
    end
  end

  # http_test_result — the response × parsed split the Test fills, so the
  # operator sees the shape they're mapping against and confirms it resolves.
  def http_test_result
    div(class: "flex flex-col gap-1.5") do
      span(data: {dashboard_builder_target: "httpTestStatus"}, class: "text-[11px] text-voodu-muted min-w-0 truncate")
      div(hidden: true, data: {dashboard_builder_target: "httpTestResult"}, class: "grid grid-cols-2 gap-2") do
        http_test_pane("Response", "httpTestRaw")
        http_test_pane("Parsed", "httpTestParsed")
      end
    end
  end

  def http_test_pane(title, target)
    div(class: "flex flex-col gap-1 min-w-0") do
      span(class: "text-[10px] uppercase tracking-[0.06em] text-voodu-muted-2") { title }
      # `voodu-code` scopes the .tok-* color rules so the controller can paint
      # JSON tokens into this pane (renderHttpTest sets innerHTML on a hit).
      pre(
        data: {dashboard_builder_target: target},
        class: "voodu-code max-h-[180px] overflow-auto text-[11px] font-voodu-mono text-voodu-text-2 bg-voodu-bg-2 border border-voodu-border p-2 whitespace-pre-wrap break-all"
      )
    end
  end

  # http_color_swatches — mirrors the table swatches so http panels get a
  # distinct accent. Reuses the same selectHttpColor handler + httpSwatch target.
  def http_color_swatches
    div(class: "flex items-center gap-1.5 flex-wrap shrink-0") do
      LOG_COLORS.each do |c|
        button(
          type: "button",
          title: c,
          "aria-label": "Use accent #{c}",
          data: {dashboard_builder_target: "httpSwatch", color: c, action: "click->dashboard-builder#selectHttpColor"},
          class: "w-5 h-5 rounded-full border border-voodu-border shrink-0 data-[active=true]:ring-2 data-[active=true]:ring-voodu-accent-line",
          style: "background: #{c};"
        )
      end
    end
  end

  # hep3_percent_toggle — for a HEP3 gauge (Radial/Linear): show the center as
  # the fill "%" (of the range peak) instead of the raw count. Off by default —
  # a count reads clearer as a number. The builder reveals it only for gauges.
  def hep3_percent_toggle
    label(hidden: true, data: {dashboard_builder_target: "hep3PercentRow"}, class: "flex items-center gap-2 cursor-pointer select-none") do
      input(
        type: "checkbox",
        data: {dashboard_builder_target: "hep3Percent", action: "change->dashboard-builder#autoCommit"},
        class: "w-4 h-4 shrink-0 cursor-pointer",
        style: "accent-color: var(--voodu-accent);"
      )
      span(class: "text-[12px] text-voodu-text-2") { "Show as %" }
      span(class: "text-[11px] text-voodu-muted") { "— fill % of the peak instead of the count" }
    end
  end

  # hep3_shape_chips — the HEP3 kind's visualization picker (Table rows OR a
  # count chart). Hidden until the builder activates the hep3 kind; the Table
  # (logs) kind only tabulates, so it stays hidden there.
  def hep3_shape_chips
    div(hidden: true, data: {dashboard_builder_target: "hep3Shapes"}, class: "flex flex-wrap gap-2.5") do
      hep3_shape_chip("table", "Table") { table_preview_svg }
      hep3_shape_chip("number", "Number") { log_preview_svg }
      hep3_shape_chip("area", "Area") { render Components::Metrics::ChartShape.new(type: "area") }
      hep3_shape_chip("bars", "Bar") { render Components::Metrics::ChartShape.new(type: "bars") }
      hep3_shape_chip("line", "Line") { render Components::Metrics::ChartShape.new(type: "line") }
      hep3_shape_chip("gauge_radial", "Radial") { render Components::Metrics::ChartShape.new(type: "gauge_radial") }
      hep3_shape_chip("gauge_linear", "Linear") { render Components::Metrics::ChartShape.new(type: "gauge_linear") }
    end
  end

  def hep3_shape_chip(value, text)
    button(
      type: "button",
      data: {action: "click->dashboard-builder#selectHep3Shape", chart_type: value, dashboard_builder_target: "hep3ShapeChip"},
      class: "flex flex-col w-[110px] max-w-full overflow-hidden border border-voodu-border-2 bg-voodu-surface text-left hover:border-voodu-accent-line hover:bg-voodu-surface-2 transition-colors"
    ) do
      div(class: "h-[52px] w-full flex items-center justify-center px-3 py-2 border-b border-voodu-border-2 bg-voodu-surface-2/40 text-voodu-muted") { yield }
      span(class: "block text-[12px] font-medium text-voodu-text px-2.5 py-1.5") { text }
    end
  end

  # table_filter_editor — the optional pre-filter, the SAME DSL + editor as
  # /logs Analytics + the log panel (@to_user like /5511/, and/or/not), but
  # validated against the table's own fields. The table opens filtered; the
  # toolbar query is seeded from it.
  def table_filter_editor
    render Components::UI::QueryEditor.new(
      value: "",
      submits: false,
      rows: "2",
      min_h: "min-h-[64px]",
      help_limit: false,
      fields: DataTable::LogsSource::FIELDS,
      placeholder: "filter (optional) — e.g. @message like /error/",
      input_data: {dashboard_builder_target: "tableQuery"}
    )
  end

  # TABLE_FILTER_HINTS — short notes shown beside each field in the `@`
  # autocomplete. Best-effort: a field with no note still lists (name only).
  TABLE_FILTER_HINTS = {
    "ts" => "capture time",
    "method" => "SIP method (INVITE, BYE…)",
    "response_code" => "SIP response (200, 486…)",
    "from_user" => "From user",
    "to_user" => "To user",
    "ruri" => "request URI",
    "src_ip" => "source IP",
    "src_port" => "source port",
    "dst_ip" => "destination IP",
    "dst_port" => "destination port",
    "call_id" => "SIP Call-ID",
    "corr_id" => "correlated call (x_cid ?? call_id)",
    "x_cid" => "correlation header",
    "user_agent" => "SIP User-Agent",
    "cseq" => "CSeq header",
    "node_id" => "capture node",
    "started_at" => "first message time",
    "last_ts" => "last message time",
    "methods" => "methods seen in the call",
    "messages" => "message count",
    "last_code" => "final response code"
  }.freeze

  # hep3_filter_fields — every field any HEP3 view exposes, for the query
  # editor's client-side "names a field?" validation (the server enforces the
  # per-view allowlist). The Table (logs) kind uses LogsSource::FIELDS instead;
  # the builder swaps the editor's fields when the operator picks a kind.
  def hep3_filter_fields
    hep3_source_views.flat_map { |sv| sv[:fields] }.uniq
  end

  def table_label_input
    input(
      type: "text",
      placeholder: "Label — e.g. SIP messages",
      autocomplete: "off",
      data: {dashboard_builder_target: "tableLabel", action: "input->dashboard-builder#autoCommit"},
      class: "vmd:flex-1 min-w-0 h-9 px-2.5 border border-voodu-border bg-voodu-surface text-voodu-text text-[12.5px] placeholder:text-voodu-muted-2 focus:outline-none focus:border-voodu-accent-line"
    )
  end

  # table_source_view_picker — the combined source·view dropdown, one entry
  # per (source, view): "HEP3 — Messages", "HEP3 — Calls", "HEP3 — Errors".
  # Selecting one sets both + repopulates the filter-field options.
  # table_source_view_picker — the kind's option dropdown. The menu is
  # populated by the builder (dashboard-builder#activateTableKind) from the
  # logs pods OR the hep3 readers, depending on the chosen type — so one block
  # serves both the Table and HEP3 kinds.
  def table_source_view_picker
    div(class: "vmd:w-[220px] shrink-0 relative", data: {controller: "dropdown"}) do
      picker_trigger("Select data", :tableSourceViewLabel)
      div(hidden: true, data: {dropdown_target: "menu", dashboard_builder_target: "tableSourceMenu"}, class: menu_classes)
    end
  end

  # table_color_swatches — accent for the table panel's title. Reuses the
  # log palette (a table has no canonical per-metric color).
  def table_color_swatches
    div(class: "flex items-center gap-1.5 flex-wrap") do
      LOG_COLORS.each do |c|
        button(
          type: "button",
          title: c,
          "aria-label": "Use accent #{c}",
          data: {action: "click->dashboard-builder#selectTableColor", dashboard_builder_target: "tableSwatch", color: c},
          class: "w-5 h-5 rounded-full border border-voodu-border shrink-0",
          style: "background: #{c};"
        )
      end
      custom_color_swatch(name: "table")
    end
  end

  # change_type_link — the config block's secondary action. The controller
  # relabels it per mode: "Change type" while adding (→ back to the type
  # cards), "Cancel" while editing (→ back to the idle placeholder,
  # deselecting). Rendered in both blocks, so the target is plural.
  def change_type_link
    button(
      type: "button",
      data: {action: "click->dashboard-builder#backToTypes"},
      class: "inline-flex items-center gap-1 text-[11.5px] text-voodu-muted hover:text-voodu-text"
    ) do
      render Icon::ArrowLeftOutline.new(class: "w-3 h-3")
      span(data: {dashboard_builder_target: "backLink"}) { "Change type" }
    end
  end

  # add_panel_row — source + metric pickers (DS dropdowns) + shape chips.
  # No Add button: picking a source/metric/shape auto-saves the panel into
  # the list (dashboard-builder#autoCommit). Stacks on narrow, inline at vmd+.
  def add_panel_row
    div(hidden: true, data: {dashboard_builder_target: "metricBlock"}, class: "flex flex-col gap-2.5 p-3 border border-voodu-border-2 bg-voodu-surface") do
      div(class: "flex items-center justify-between gap-2") do
        span(
          data: {dashboard_builder_target: "metricBlockTitle"},
          class: "text-[11.5px] font-medium text-voodu-text-2 uppercase tracking-[0.04em]"
        ) { "Metric panel" }
        change_type_link
      end

      div(class: "flex flex-col vmd:flex-row gap-2") do
        metric_picker
        source_picker
      end

      metric_query_editor
      shape_chips
      metric_color_swatches
      metric_timeline_toggle
    end
  end

  # metric_timeline_toggle — a Number render's "Show timeline chart" switch: draw
  # the tile as a bare number, or number + sparkline. Only meaningful for Number,
  # so the builder reveals this row (metricTimelineRow) only when that render is
  # picked. Writes `show_chart` on the panel; the read path (MetricDashboardData
  # #show_chart?) drops the series when off. Mirrors log_show_chart_toggle.
  def metric_timeline_toggle
    div(hidden: true, data: {dashboard_builder_target: "metricTimelineRow"}, class: "flex flex-col gap-2") do
      label(class: "flex items-center gap-2 cursor-pointer select-none mt-0.5") do
        input(
          type: "checkbox",
          checked: true,
          data: {dashboard_builder_target: "metricShowChart", action: "change->dashboard-builder#autoCommit"},
          class: "w-4 h-4 shrink-0 cursor-pointer",
          style: "accent-color: var(--voodu-accent);"
        )
        span(class: "text-[12px] text-voodu-text-2") { "Show timeline chart" }
        span(class: "text-[11px] text-voodu-muted") { "— number + area over time" }
      end
    end
  end

  # metric_query_editor — the LogQuery filter, shown only when the measure is
  # "Query" (the builder toggles metricQueryRow). Same DSL + editor as the
  # /logs Analytics filter, so a query prototyped there pastes in verbatim; the
  # builder reads the text via the metricQuery target and routes it to a log /
  # table panel depending on the chosen render.
  def metric_query_editor
    div(hidden: true, data: {dashboard_builder_target: "metricQueryRow"}, class: "flex flex-col gap-2") do
      render Components::UI::QueryEditor.new(
        value: "",
        submits: false,
        rows: "3",
        min_h: "min-h-[120px]",
        help_limit: false,
        show_stats: true,
        fields: DataTable::LogsSource::FIELDS,
        placeholder: "@message like /INVITE/  ·  … | count",
        input_data: {dashboard_builder_target: "metricQuery"}
      )
    end
  end

  # metric_color_swatches — override the metric's canonical chart color.
  # Defaults to the metric's own color (highlighted on select); picking
  # another recolors the shape previews live + the rendered chart.
  def metric_color_swatches
    div(class: "flex items-center gap-2 flex-wrap pt-0.5") do
      span(class: "text-[11px] text-voodu-muted-2 uppercase tracking-[0.04em]") { "Color" }
      div(class: "flex items-center gap-1.5 flex-wrap") do
        METRIC_COLORS.each do |c|
          button(
            type: "button",
            title: c,
            "aria-label": "Use color #{c}",
            data: {action: "click->dashboard-builder#selectMetricColor", dashboard_builder_target: "metricSwatch", color: c},
            class: "w-5 h-5 rounded-full border border-voodu-border shrink-0",
            style: "background: #{c};"
          )
        end
        custom_color_swatch(name: "metric")
      end
    end
  end

  # custom_color_swatch — a "+" trigger that opens the DS color picker
  # (Components::UI::ColorPicker) in a popover. The picker dispatches a
  # `color-picker:change` event the dashboard-builder applies; `name`
  # ("log"/"metric") tells it which panel kind to colour.
  def custom_color_swatch(name:)
    swatch_action = {"log" => "selectLogColor", "table" => "selectTableColor"}.fetch(name, "selectMetricColor")

    div(class: "flex items-center gap-1.5") do
      # The chosen custom color, added to the row as a re-selectable swatch
      # (hidden until one is picked / a hex panel is loaded). It's a normal
      # *Swatch target so the active-ring logic + selection reuse it.
      button(
        type: "button",
        hidden: true,
        title: "Custom color",
        data: {action: "click->dashboard-builder##{swatch_action}", dashboard_builder_target: "#{name}Swatch", role: "custom-#{name}"},
        class: "w-5 h-5 rounded-full border border-voodu-border shrink-0"
      )

      div(class: "relative", data: {controller: "popover"}) do
        button(
          type: "button",
          title: "Custom color",
          "aria-label": "Pick a custom color",
          data: {action: "click->popover#toggle", popover_target: "trigger"},
          class: "w-5 h-5 rounded-full border border-dashed border-voodu-muted-2 shrink-0 cursor-pointer " \
                 "inline-flex items-center justify-center text-voodu-muted-2 hover:text-voodu-text hover:border-voodu-text"
        ) { render Icon::PlusOutline.new(class: "w-3 h-3") }

        div(hidden: true, data: {popover_target: "menu"}) do
          render Components::UI::ColorPicker.new(name: name)
        end
      end
    end
  end

  # source_picker — static menu (Host + each workload), rendered server side,
  # enumerated across EVERY server in the org (M2). Selecting one updates the
  # trigger label, stamps the panel's server_id (it rides in the option), and
  # repopulates the metric picker for that source's kind.
  def source_picker
    sources_count = host_sources.size + workloads.size

    div(class: "vmd:flex-1 min-w-0 relative", data: {controller: "dropdown"}) do
      picker_trigger(default_source_label, :sourceLabel)
      div(hidden: true, data: {dropdown_target: "menu"}, class: menu_classes) do
        dropdown_filter("Filter servers + pods…") if sources_count > FILTER_THRESHOLD
        host_sources.each { |h| source_option(h, source_text(h)) }
        workloads.each { |w| source_option(w, source_text(w)) }
        dropdown_empty if sources_count > FILTER_THRESHOLD
      end
    end
  end

  # Show the in-dropdown search box only once a picker holds more rows than this
  # — a filter on a 3-item list is noise; org-wide pod lists (the reason it
  # exists) blow well past it.
  FILTER_THRESHOLD = 6

  # dropdown_filter — a sticky search box at the top of a dropdown menu. Rows
  # tagged data-dropdown-target="option" filter live as the operator types
  # (dropdown#filterInput); Enter picks the top match (dropdown#onFilterKey,
  # which also stops Enter from submitting the builder form).
  # dropdown_filter + dropdown_empty live in Views::Base (shared with the
  # alert-rule form's pickers).

  # host_sources — one Host (system) row per server; a host panel binds to that
  # server's node metrics. server_id rides in the option so buildPanel stamps it.
  def host_sources
    @server_pods.map do |server, _|
      {scope_kind: "host", server_id: server.id.to_s, server: server.name.to_s, label: "host"}
    end
  end

  # source_text — a source dropdown row's label, ALWAYS "<server> · <base>" so the
  # server owning a host/pod is explicit even in a single-server org (an org can
  # grow to N servers, and "host" / a pod name alone is ambiguous across them).
  # Host → "<server> · Host (system)"; pod → "<server> · <pod> · <kind>".
  def source_text(src)
    base = (src[:scope_kind] == "host") ? "Host (system)" : "#{src[:label]} · #{src[:kind]}"

    "#{src[:server]} · #{base}"
  end

  # default_source_label — the source trigger's resting label before a pick:
  # the default server's host (matches the JS default currentSource).
  def default_source_label
    "#{@server&.name} · Host (system)"
  end

  # metric_picker — the Type/measure dropdown, picked FIRST. The builder fills it
  # with the FULL measure set (every measure across all workload kinds) + Query,
  # independent of the source, so the operator chooses what to measure and then
  # where. "Query" opens the LogQuery editor; a measure a source doesn't emit
  # just reads empty (no filtering — the operator owns the pairing).
  def metric_picker
    div(class: "vmd:flex-1 min-w-0 relative", data: {controller: "dropdown"}) do
      picker_trigger("Select type", :metricLabel)
      div(hidden: true, data: {dropdown_target: "menu", dashboard_builder_target: "metricMenu"}, class: menu_classes)
    end
  end

  # shape_chips — chart shape picker as the SAME square card pattern as the
  # panel-type chooser: a skeleton preview up top + a label below. Gauge cards
  # carry data-gauge="true"; the builder hides them + snaps back to Area when
  # the metric has no ceiling. The Number + Table cards carry
  # data-measure="query": they're offered only when the measure is "Query" (a
  # count → a big number, or the matching lines → a table), and hidden for a
  # warehouse metric. The active card is ringed in JS (highlightShape).
  def shape_chips
    div(class: "flex flex-wrap gap-2.5") do
      shape_chip("number", "Number", measure: "query") { log_preview_svg }
      Components::Metrics::ChartShape::METRIC_TYPES.each do |t|
        shape_chip(t[:value], t[:label], gauge: t[:gauge]) do
          render Components::Metrics::ChartShape.new(type: t[:value])
        end
      end
      shape_chip("table", "Table", measure: "query") { table_preview_svg }
    end
  end

  def shape_chip(value, text, gauge: false, measure: nil)
    data = {action: "click->dashboard-builder#selectType", chart_type: value, dashboard_builder_target: "shapeChip"}
    data[:gauge] = "true" if gauge
    data[:measure] = measure if measure

    button(
      type: "button",
      data: data,
      class: "flex flex-col w-[130px] max-w-full overflow-hidden border border-voodu-border-2 bg-voodu-surface text-left hover:border-voodu-accent-line hover:bg-voodu-surface-2 transition-colors"
    ) do
      # text color (currentColor of the skeleton) is set live by the builder
      # to the chosen metric color, so the preview shows the real chart hue.
      div(
        data: {dashboard_builder_target: "shapeSkeleton"},
        class: "h-[58px] w-full flex items-center justify-center px-3 py-2 border-b border-voodu-border-2 bg-voodu-surface-2/40 text-voodu-muted"
      ) { yield }
      span(class: "block text-[12px] font-medium text-voodu-text px-2.5 py-2") { text }
    end
  end

  def picker_trigger(label_text, target)
    button(
      type: "button",
      data: {action: "click->dropdown#toggle"},
      class: "inline-flex items-center gap-2 px-2.5 h-9 w-full border border-voodu-border bg-voodu-surface text-voodu-text hover:bg-voodu-surface-2"
    ) do
      span(
        class: "min-w-0 truncate flex-1 text-left text-[12.5px] text-voodu-text",
        data: {dashboard_builder_target: target}
      ) { label_text }
      render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 text-voodu-muted shrink-0")
    end
  end

  def source_option(src, text)
    # No `dropdown#close` here — the controller closes it in single-select mode
    # but keeps it OPEN while multi-selecting pods (Line multi-series). The
    # data-selected accent + trailing check are toggled by dashboard-builder.
    button(
      type: "button",
      data: {action: "click->dashboard-builder#selectSource", dropdown_target: "option", source: src.to_json},
      class: "#{option_classes} group data-[selected=true]:bg-voodu-accent-dim data-[selected=true]:text-voodu-accent-2"
    ) do
      span(class: "flex-1 truncate") { text }
      span(class: "shrink-0 text-voodu-accent-2 opacity-0 group-data-[selected=true]:opacity-100") { "✓" }
    end
  end

  # add_log_panel_row — the log-count panel builder. A pod source (logs are
  # per-pod), a label, the LogQuery filter (same DSL as /logs/analytics), and
  # an accent color. No Add button: source/label/query/color edits auto-save
  # the panel (dashboard-builder#autoCommit). Stacks on narrow viewports; the
  # query input stays full-width (it's the long field).
  def add_log_panel_row
    div(hidden: true, data: {dashboard_builder_target: "logBlock"}, class: "flex flex-col flex-1 min-h-0 gap-2.5 p-3 border border-voodu-border-2 bg-voodu-surface") do
      div(class: "flex items-center justify-between gap-2") do
        span(
          data: {dashboard_builder_target: "logBlockTitle"},
          class: "text-[11.5px] font-medium text-voodu-text-2 uppercase tracking-[0.04em]"
        ) { "Log count" }
        change_type_link
      end
      span(class: "text-[11px] text-voodu-muted leading-relaxed") do
        "Count log lines matching a filter over the dashboard range — same query language as Analytics."
      end

      div(class: "flex flex-col vmd:flex-row gap-2") do
        log_source_picker
        input(
          type: "text",
          placeholder: "Label — e.g. Calls (INVITE)",
          autocomplete: "off",
          data: {dashboard_builder_target: "logLabel", action: "input->dashboard-builder#autoCommit"},
          class: "vmd:flex-1 min-w-0 h-9 px-2.5 border border-voodu-border bg-voodu-surface text-voodu-text text-[12.5px] placeholder:text-voodu-muted-2 focus:outline-none focus:border-voodu-accent-line"
        )
      end

      # Shared LogQuery editor (highlight + field validation + cheatsheet).
      # submits:false → Cmd+Enter validates but never POSTs the dashboard form
      # mid-edit; the builder reads the value via the logQuery target.
      #
      # grow:false (NOT flex-fill) so `resize-y` actually works — a flex-1 shell
      # has its height recomputed by the flex layout every frame, which stomps
      # the height the operator drags the resize handle to (the editor reads as
      # "stuck"). A comfortable min height + manual resize is the right model.
      render Components::UI::QueryEditor.new(
        value: "",
        submits: false,
        rows: "3",
        min_h: "min-h-[240px]",
        help_limit: false,
        show_stats: true,
        placeholder: "@message like /INVITE/  ·  … | avg",
        input_data: {dashboard_builder_target: "logQuery"}
      )

      color_swatches
      log_show_chart_toggle
    end
  end

  # log_show_chart_toggle — lets the operator pick "just the number" vs "number
  # + timeline chart". Checked by default (new panels show the chart); toggling
  # auto-saves the panel like every other field. The read path (MetricDashboard
  # Data#show_chart?) drops the series when unchecked, so the NumberCard renders
  # the count alone.
  def log_show_chart_toggle
    label(class: "flex items-center gap-2 cursor-pointer select-none mt-0.5") do
      input(
        type: "checkbox",
        checked: true,
        data: {dashboard_builder_target: "logShowChart", action: "change->dashboard-builder#autoCommit"},
        class: "w-4 h-4 shrink-0 cursor-pointer",
        style: "accent-color: var(--voodu-accent);"
      )
      span(class: "text-[12px] text-voodu-text-2") { "Show timeline chart" }
      span(class: "text-[11px] text-voodu-muted") { "— number + area over time" }
    end
  end

  # log_source_picker — workloads only (host has no per-pod logs). Selecting
  # one sets the panel's scope/name; the metric picker is irrelevant here.
  def log_source_picker
    div(class: "vmd:w-[200px] shrink-0 relative", data: {controller: "dropdown"}) do
      picker_trigger("Select pod", :logSourceLabel)
      div(hidden: true, data: {dropdown_target: "menu"}, class: menu_classes) do
        if workloads.empty?
          div(class: "px-3 py-2 text-[12px] text-voodu-muted") { "No pods in this org" }
        else
          dropdown_filter("Filter pods…") if workloads.size > FILTER_THRESHOLD
          workloads.each { |w| log_source_option(w, source_text(w)) }
          dropdown_empty if workloads.size > FILTER_THRESHOLD
        end
      end
    end
  end

  def log_source_option(src, text)
    button(
      type: "button",
      data: {action: "click->dashboard-builder#selectLogSource click->dropdown#close", dropdown_target: "option", source: src.to_json},
      class: option_classes
    ) { text }
  end

  # color_swatches — accent picker for the count tile. Inline-style fill (the
  # tokens are CSS vars, not Tailwind classes); the active ring is toggled in
  # JS via outline (also CSS-var driven) so nothing here depends on a
  # purge-scanned class.
  def color_swatches
    div(class: "flex items-center gap-1.5 flex-wrap") do
      LOG_COLORS.each do |c|
        button(
          type: "button",
          title: c,
          "aria-label": "Use accent #{c}",
          data: {action: "click->dashboard-builder#selectLogColor", dashboard_builder_target: "logSwatch", color: c},
          class: "w-5 h-5 rounded-full border border-voodu-border shrink-0",
          style: "background: #{c};"
        )
      end
      custom_color_swatch(name: "log")
    end
  end

  def menu_classes
    "absolute left-0 top-[calc(100%+4px)] z-30 min-w-[200px] w-full max-h-[280px] overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface shadow-2xl"
  end

  def option_classes
    "flex items-center gap-2.5 w-full px-3 py-2 min-h-[34px] text-left text-[12.5px] text-voodu-text hover:bg-voodu-hover"
  end

  def hidden_panels_input
    input(
      type: "hidden",
      name: "metric_dashboard[panels]",
      data: {dashboard_builder_target: "hidden"}
    )
  end

  # footer_actions — the form's action bar, pinned to the bottom of the
  # CONTENT column (not under the panels sidebar, which stays a clean
  # second sidebar). A top border separates it from the detail editor;
  # Save sits right. shrink-0 so it never compresses as the detail scrolls.
  def footer_actions
    div(class: "flex items-center justify-end gap-2 pt-3 mt-1 border-t border-voodu-border shrink-0") do
      button(
        type: "submit",
        class: "inline-flex items-center justify-center gap-1.5 px-3.5 h-9 border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 text-[12.5px] font-medium hover:bg-voodu-accent/20"
      ) do
        render Icon::CheckOutline.new(class: "w-3.5 h-3.5")
        span { @dashboard.persisted? ? "Save changes" : "Create dashboard" }
      end
    end
  end

  # delete_button — icon-only Turbo DELETE (with confirm) on the title row,
  # right of the pin. _top so the destroy redirect (→ /metrics) navigates
  # the whole page, not the frame.
  def delete_button
    a(
      href: metric_dashboard_path(@dashboard),
      data: {turbo_method: :delete, turbo_confirm: "Delete dashboard “#{@dashboard.name}”?", turbo_confirm_theme: "danger", turbo_frame: "_top"},
      title: "Delete dashboard", "aria-label": "Delete dashboard",
      class: "inline-flex items-center justify-center w-9 h-9 shrink-0 border border-voodu-border bg-voodu-surface text-voodu-muted hover:text-voodu-red hover:border-voodu-red/40 hover:bg-voodu-red-dim"
    ) { render Icon::TrashOutline.new(class: "w-4 h-4") }
  end

  def form_action
    @dashboard.persisted? ? metric_dashboard_path(@dashboard) : metric_dashboards_path
  end

  # workloads — unique (server_id, scope, resource_name, kind) tuples across
  # EVERY server in the org (M2). Panels bind to the WORKLOAD, not a replica, so
  # the picker offers one row per workload regardless of replica count; each
  # row carries the server_id it lives on (the same workload name on two servers
  # stays two distinct rows). `server` labels it when the org is multi-server.
  def workloads
    @workloads ||= @server_pods.flat_map do |server, pods|
      Array(pods).map do |p|
        {
          scope_kind: "pod",
          server_id: server.id.to_s,
          server: server.name.to_s,
          scope: (p["scope"] || p[:scope]).to_s,
          name: (p["resource_name"] || p[:resource_name]).to_s,
          kind: (p["kind"] || p[:kind]).to_s.presence || "pod",
          label: (p["resource_name"] || p[:resource_name]).to_s
        }
      end.reject { |w| w[:scope].empty? || w[:name].empty? }
        .uniq { |w| [w[:server_id], w[:scope], w[:name], w[:kind]] }
    end.sort_by { |w| [w[:server], w[:scope], w[:name]] }
  end

  # catalog_json — { kind => [spec, …] } the builder's metric <select>
  # reads. "host" plus one entry per distinct workload kind present, so
  # the metric options match whatever source the operator picks.
  def catalog_json
    kinds = (["host"] + workloads.map { |w| w[:kind] }).uniq

    kinds.each_with_object({}) do |kind, acc|
      scope_kind = (kind == "host") ? "host" : "pod"
      acc[kind] = MetricsPageData.metric_catalog_for(scope_kind, kind).map { |s| spec_json(s) }
    end.to_json
  end

  # table_sources — DataSources offered for Table panels across the org's
  # servers ([{key:, label:, views:[…]}], from DataTable::Registry), deduped by
  # key (a source's shape is server-independent; only availability varies). The
  # Table/HEP3/HTTP type card shows when ANY server offers that source.
  def table_sources
    @table_sources ||= @server_pods
      .flat_map { |server, _| DataTable::Registry.available(server) }
      .uniq { |s| s[:key] }
  end

  # hep3_readers — the SIP-capture reader instances across EVERY server in the
  # org (M2), detected by image (`voodu-hep3-api*`). Each folds INTO the
  # source·view options carrying its server_id + (scope, name), so a HEP3 panel
  # needs no pod picker. Empty → the HEP3 type card hides.
  def hep3_readers
    @hep3_readers ||= @server_pods.flat_map { |server, pods|
      Array(pods).filter_map do |p|
        next unless (p["image"] || p[:image]).to_s.start_with?("voodu-hep3-api")

        {server_id: server.id.to_s, server: server.name.to_s,
         scope: (p["scope"] || p[:scope]).to_s, name: (p["resource_name"] || p[:resource_name]).to_s}
      end.reject { |r| r[:scope].empty? || r[:name].empty? }
    }.uniq { |r| [r[:server_id], r[:scope], r[:name]] }
  end

  # hep3_source_views — the HEP3 kind's picker options: one entry per
  # (reader, view), each carrying the reader's server_id + scope/name so the
  # HEP3 panel needs no separate pod picker. Label prefixes the server (multi-
  # server) or reader name (several readers) so options stay distinguishable.
  def hep3_source_views
    multi = hep3_readers.size > 1

    table_sources.select { |src| src[:key] == "hep3" }.flat_map do |src|
      hep3_readers.flat_map do |reader|
        base = multi ? reader[:name] : src[:short_label]
        prefix = "#{reader[:server]} · #{base}"

        src[:views].map do |v|
          {source: src[:key], server_id: reader[:server_id], scope: reader[:scope], name: reader[:name],
           view: v[:key], label: "#{prefix} — #{v[:label]}", fields: v[:fields]}
        end
      end
    end
  end

  # logs_source_views — the Table kind's picker options: one entry per pod
  # (workload) across the org, each carrying its server_id + scope/name. The
  # generic Table tabulates that pod's logs (DataTable::LogsSource).
  def logs_source_views
    workloads.map do |w|
      {source: "logs", server_id: w[:server_id], scope: w[:scope], name: w[:name], view: "lines",
       label: source_text(w), fields: DataTable::LogsSource::FIELDS}
    end
  end

  def existing_panels_json
    Array(@dashboard.panels).to_json
  end

  def spec_json(spec)
    {
      metric: spec[:metric],
      scale: spec[:scale].to_s,
      label: spec[:label],
      color: spec[:color],
      unit: spec[:unit].to_s,
      section: spec[:section].to_s,
      # gauge — whether this metric has a ceiling a gauge can fill (a
      # percent metric, or memory/disk capacity). The builder only offers
      # the gauge types when true. Net/HTTP rates have no max → area only.
      gauge: gauge_metric?(spec)
    }
  end

  def gauge_metric?(spec)
    spec[:scale].to_s == "percent" || spec[:metric].to_s.start_with?("mem", "disk")
  end
end
