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
  FRAME_ID = "dashboards-panel"

  # Accent palette offered for log-count panels. A count has no canonical
  # per-metric color (it isn't CPU/Memory/…), so the operator picks one.
  # Drawn from the chart palette tokens; red stays available for "errors"
  # counts (a 5xx / 480-Cancel filter).
  LOG_COLORS = %w[
    var(--voodu-orange) var(--voodu-amber) var(--voodu-green)
    var(--voodu-blue) var(--voodu-purple) var(--voodu-pink)
    var(--voodu-teal) var(--voodu-red)
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
    turbo_frame_tag(FRAME_ID) do
      div(class: "flex flex-col") do
        builder_header
        error_banner if @dashboard.errors.any?
        builder_form
      end
    end
  end

  def builder_header
    div(class: "flex items-center gap-2 px-4 py-3 border-b border-voodu-border") do
      a(
        href: metric_dashboards_path,
        title: "Back to dashboards",
        class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 shrink-0"
      ) { render Icon::ArrowLeftOutline.new(class: "w-4 h-4") }

      span(class: "text-[13px] font-semibold text-voodu-text truncate") do
        @dashboard.persisted? ? "Edit dashboard" : "New dashboard"
      end
    end
  end

  def error_banner
    div(class: "mx-4 mt-3 px-3 py-2 border border-voodu-red/40 bg-voodu-red-dim text-voodu-red text-[12px]") do
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
        dashboard_builder_panels_value: existing_panels_json
      },
      class: "flex flex-col gap-4 px-4 py-4"
    ) do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      input(type: "hidden", name: "_method", value: "patch") if @dashboard.persisted?
      # return_to — the /metrics URL the operator opened the builder from
      # (often a multi-dashboard ?pid=a,b view). Carried through so a
      # save lands them back on the exact view they were on, not the
      # single edited dashboard.
      input(type: "hidden", name: "return_to", value: @return_to) if @return_to.present?

      name_field
      add_type_toggle
      add_panel_row
      add_log_panel_row
      panels_list
      hidden_panels_input
      footer_actions
    end
  end

  def name_field
    label(class: "flex flex-col gap-1.5") do
      span(class: "text-[11.5px] font-medium text-voodu-text-2 uppercase tracking-[0.04em]") { "Name" }
      input(
        type: "text",
        name: "metric_dashboard[name]",
        value: @dashboard.name,
        placeholder: "prod overview",
        autocomplete: "off",
        class: "h-9 px-2.5 border border-voodu-border bg-voodu-surface text-voodu-text text-[13px] placeholder:text-voodu-muted-2 focus:outline-none focus:border-voodu-accent-line"
      )
    end
  end

  # add_type_toggle — segmented control that picks which "add" block shows
  # (Metric vs Log count), so the two builders don't compete for vertical
  # space. The active state is painted by the builder controller via inline
  # style (CSS-var colors) so it survives Tailwind purge without a safelist.
  def add_type_toggle
    div(class: "flex items-stretch gap-1 p-0.5 border border-voodu-border bg-voodu-surface w-full vmd:w-[300px]") do
      add_type_button("metric", "Metric")
      add_type_button("log", "Log count")
    end
  end

  def add_type_button(value, text)
    # Seed "metric" active (the default block) so the toggle paints right
    # before Stimulus connects; the controller keeps it in sync after.
    active = value == "metric"
    style = active ? "background: var(--voodu-accent-dim); color: var(--voodu-accent-2);" : "color: var(--voodu-text-2);"

    button(
      type: "button",
      data: {action: "click->dashboard-builder#setAddType", add_type: value, dashboard_builder_target: "addTypeBtn"},
      style: style,
      class: "flex-1 inline-flex items-center justify-center h-8 text-[12px] font-medium transition-colors"
    ) { text }
  end

  # add_panel_row — source + metric pickers (DS dropdowns) + Add.
  # Stacks on narrow viewports, sits inline at vmd+. The dropdown
  # controller owns open/close; dashboard-builder owns the selection.
  def add_panel_row
    div(class: "flex flex-col gap-2 p-3 border border-voodu-border-2 bg-voodu-surface", data: {dashboard_builder_target: "metricBlock"}) do
      span(class: "text-[11.5px] font-medium text-voodu-text-2 uppercase tracking-[0.04em]") { "Add panel" }

      div(class: "flex flex-col vmd:flex-row gap-2") do
        source_picker
        metric_picker
        type_picker
        add_button
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

  # type_picker — chart type for the panel (Area / Gauge radial / Gauge
  # linear). The gauge options carry data-gauge="true"; the builder
  # controller hides them (and snaps back to Area) when the selected
  # metric has no ceiling, so you can only gauge a percent/capacity metric.
  def type_picker
    div(class: "vmd:w-[156px] shrink-0 relative", data: {controller: "dropdown"}) do
      picker_trigger("Area", :typeLabel)
      div(hidden: true, data: {dropdown_target: "menu", dashboard_builder_target: "typeMenu"}, class: menu_classes) do
        type_option("area", "Area")
        type_option("gauge_radial", "Gauge · radial", gauge: true)
        type_option("gauge_linear", "Gauge · linear", gauge: true)
      end
    end
  end

  def type_option(value, text, gauge: false)
    data = {action: "click->dashboard-builder#selectType click->dropdown#close", chart_type: value}
    data[:gauge] = "true" if gauge

    button(type: "button", data: data, class: option_classes) { text }
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

  def add_button
    button(
      type: "button",
      data: {action: "click->dashboard-builder#add"},
      class: "inline-flex items-center justify-center gap-1.5 px-3 h-9 border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 text-[12.5px] font-medium hover:bg-voodu-accent/20 shrink-0"
    ) do
      render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
      span { "Add" }
    end
  end

  # add_log_panel_row — the log-count panel builder. A pod source (logs are
  # per-pod), a label, the LogQuery filter (same DSL as /logs/analytics), and
  # an accent color → "Add count" appends a scope_kind:"log" panel. The count
  # spans the dashboard's global range and renders as a NumberCard. Stacks on
  # narrow viewports; the query input stays full-width (it's the long field).
  def add_log_panel_row
    div(hidden: true, data: {dashboard_builder_target: "logBlock"}, class: "flex flex-col gap-2.5 p-3 border border-voodu-border-2 bg-voodu-surface") do
      span(class: "text-[11.5px] font-medium text-voodu-text-2 uppercase tracking-[0.04em]") { "Add log count" }
      span(class: "text-[11px] text-voodu-muted leading-relaxed") do
        "Count log lines matching a filter over the dashboard range — same query language as Analytics."
      end

      div(class: "flex flex-col vmd:flex-row gap-2") do
        log_source_picker
        input(
          type: "text",
          placeholder: "Label — e.g. Calls (INVITE)",
          autocomplete: "off",
          data: {dashboard_builder_target: "logLabel"},
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
        min_h: "min-h-[84px]",
        help_limit: false,
        show_stats: true,
        placeholder: "@message like /INVITE/  ·  … | avg",
        input_data: {dashboard_builder_target: "logQuery"}
      )

      div(class: "flex items-center gap-2 flex-wrap") do
        color_swatches
        div(class: "flex-1")
        add_log_button
      end
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
    end
  end

  def add_log_button
    button(
      type: "button",
      data: {action: "click->dashboard-builder#addLog"},
      class: "inline-flex items-center justify-center gap-1.5 px-3 h-9 border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 text-[12.5px] font-medium hover:bg-voodu-accent/20 shrink-0"
    ) do
      render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
      span { "Add count" }
    end
  end

  def menu_classes
    "absolute left-0 top-[calc(100%+4px)] z-30 min-w-[200px] w-full max-h-[280px] overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface shadow-2xl"
  end

  def option_classes
    "flex items-center gap-2.5 w-full px-3 py-2 min-h-[34px] text-left text-[12.5px] text-voodu-text hover:bg-voodu-hover"
  end

  # panels_list — chips rendered by the Stimulus controller from the
  # in-memory list; the empty hint shows until the first panel lands.
  def panels_list
    div(class: "flex flex-col gap-2") do
      span(class: "text-[11.5px] font-medium text-voodu-text-2 uppercase tracking-[0.04em]") { "Panels" }
      div(data: {dashboard_builder_target: "list"}, class: "flex flex-col gap-1.5")
      div(
        data: {dashboard_builder_target: "empty"},
        class: "text-[11.5px] text-voodu-muted px-1"
      ) { "No panels yet — pick a source + metric above and press Add." }
    end
  end

  def hidden_panels_input
    input(
      type: "hidden",
      name: "metric_dashboard[panels]",
      data: {dashboard_builder_target: "hidden"}
    )
  end

  def footer_actions
    div(class: "flex items-center gap-2 pt-2") do
      a(
        href: metric_dashboards_path,
        class: "inline-flex items-center justify-center px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
      ) { "Cancel" }

      div(class: "flex-1")

      button(
        type: "submit",
        class: "inline-flex items-center justify-center gap-1.5 px-3.5 h-9 border border-voodu-accent-line bg-voodu-accent text-voodu-on-accent text-[12.5px] font-medium hover:bg-voodu-accent-2"
      ) { @dashboard.persisted? ? "Save changes" : "Create dashboard" }
    end
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
