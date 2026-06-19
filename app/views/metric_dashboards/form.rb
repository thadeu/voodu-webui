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

  def initialize(island:, dashboard:, pods: [], embed: true,
    current_path: nil, islands: [], current_island: nil,
    return_to: nil)
    @island = island
    @dashboard = dashboard
    @pods = pods
    @embed = embed
    @current_path = current_path
    @islands = islands
    @current_island = current_island
    @return_to = return_to
  end

  def view_template
    if @embed
      builder_panel
    else
      render Components::Layouts::Dashboard.new(
        current_path: @current_path, islands: @islands, current_island: @current_island,
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
        type_card("metric", "Metric", "CPU, memory, network, HTTP — chart or gauge") { metric_preview_svg }
        type_card("log", "Log count", "Count log lines matching a filter — a number") { log_preview_svg }
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
        source_picker
        metric_picker
      end

      shape_chips
      metric_color_swatches
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
    swatch_action = (name == "log") ? "selectLogColor" : "selectMetricColor"

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

  # source_picker — static menu (Host + each workload), rendered server
  # side. Selecting one updates the trigger label and repopulates the
  # metric picker for that source's kind.
  def source_picker
    div(class: "vmd:flex-1 min-w-0 relative", data: {controller: "dropdown"}) do
      picker_trigger("Host (system)", :sourceLabel)
      div(hidden: true, data: {dropdown_target: "menu"}, class: menu_classes) do
        source_option({scope_kind: "host", label: "host"}, "Host (system)")
        workloads.each { |w| source_option(w, "#{w[:label]} · #{w[:kind]}") }
      end
    end
  end

  # metric_picker — menu filled by the builder controller from the
  # catalog whenever the source changes (the offered metrics depend on
  # the source's kind).
  def metric_picker
    div(class: "vmd:flex-1 min-w-0 relative", data: {controller: "dropdown"}) do
      picker_trigger("Select metric", :metricLabel)
      div(hidden: true, data: {dropdown_target: "menu", dashboard_builder_target: "metricMenu"}, class: menu_classes)
    end
  end

  # shape_chips — chart shape picker as the SAME square card pattern as the
  # panel-type chooser: a skeleton preview up top + a label below. Gauge cards
  # carry data-gauge="true"; the builder hides them + snaps back to Area when
  # the metric has no ceiling. The active card is ringed in JS (highlightShape).
  def shape_chips
    div(class: "flex flex-wrap gap-2.5") do
      shape_chip("area", "Area") { shape_area_svg }
      shape_chip("gauge_radial", "Radial", gauge: true) { shape_radial_svg }
      shape_chip("gauge_linear", "Linear", gauge: true) { shape_linear_svg }
    end
  end

  def shape_chip(value, text, gauge: false)
    data = {action: "click->dashboard-builder#selectType", chart_type: value, dashboard_builder_target: "shapeChip"}
    data[:gauge] = "true" if gauge

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

  def shape_area_svg
    svg(viewBox: "0 0 80 40", class: "w-full h-full", fill: "none", "aria-hidden": "true", preserveAspectRatio: "xMidYMid meet") do |s|
      s.polygon(points: "0,28 20,18 40,22 60,10 80,16 80,40 0,40", fill: "currentColor", opacity: "0.18")
      s.polyline(points: "0,28 20,18 40,22 60,10 80,16", stroke: "currentColor", "stroke-width": "2.5", "stroke-linejoin": "round", "stroke-linecap": "round")
    end
  end

  def shape_radial_svg
    svg(viewBox: "0 0 80 40", class: "w-full h-full", fill: "none", "aria-hidden": "true", preserveAspectRatio: "xMidYMid meet") do |s|
      s.path(d: "M14 34 A26 26 0 0 1 66 34", stroke: "var(--voodu-border-2)", "stroke-width": "5", "stroke-linecap": "round")
      s.path(d: "M14 34 A26 26 0 0 1 52 12", stroke: "currentColor", "stroke-width": "5", "stroke-linecap": "round")
    end
  end

  def shape_linear_svg
    svg(viewBox: "0 0 80 40", class: "w-full h-full", "aria-hidden": "true", preserveAspectRatio: "xMidYMid meet") do |s|
      s.rect(x: "8", y: "17", width: "64", height: "7", rx: "3.5", fill: "var(--voodu-border-2)")
      s.rect(x: "8", y: "17", width: "42", height: "7", rx: "3.5", fill: "currentColor")
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
    button(
      type: "button",
      data: {action: "click->dashboard-builder#selectSource click->dropdown#close", source: src.to_json},
      class: option_classes
    ) { text }
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
      render Components::UI::QueryEditor.new(
        value: "",
        submits: false,
        rows: "3",
        min_h: "min-h-[120px]",
        grow: true,
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
          div(class: "px-3 py-2 text-[12px] text-voodu-muted") { "No pods on this island" }
        else
          workloads.each { |w| log_source_option(w, "#{w[:label]} · #{w[:kind]}") }
        end
      end
    end
  end

  def log_source_option(src, text)
    button(
      type: "button",
      data: {action: "click->dashboard-builder#selectLogSource click->dropdown#close", source: src.to_json},
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

  # workloads — unique (scope, resource_name, kind) tuples from the
  # compact pod list. Panels bind to the WORKLOAD, not a replica, so
  # the picker offers one row per workload regardless of replica count.
  def workloads
    Array(@pods).map do |p|
      {
        scope_kind: "pod",
        scope: (p["scope"] || p[:scope]).to_s,
        name: (p["resource_name"] || p[:resource_name]).to_s,
        kind: (p["kind"] || p[:kind]).to_s.presence || "pod",
        label: (p["resource_name"] || p[:resource_name]).to_s
      }
    end.reject { |w| w[:scope].empty? || w[:name].empty? }
      .uniq { |w| [w[:scope], w[:name], w[:kind]] }
      .sort_by { |w| [w[:scope], w[:name]] }
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
