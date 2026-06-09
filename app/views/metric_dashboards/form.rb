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

  def initialize(island:, dashboard:, pods: [], embed: true,
                 current_path: nil, islands: [], current_island: nil,
                 return_to: nil)
    @island         = island
    @dashboard      = dashboard
    @pods           = pods
    @embed          = embed
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @return_to      = return_to
  end

  def view_template
    if @embed
      builder_panel
    else
      render Components::Layouts::Dashboard.new(
        current_path: @current_path, islands: @islands, current_island: @current_island
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
        turbo_frame:                       "_top",
        controller:                        "dashboard-builder",
        dashboard_builder_catalog_value:   catalog_json,
        dashboard_builder_panels_value:    existing_panels_json
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
      add_panel_row
      panels_list
      hidden_panels_input
      footer_actions
    end
  end

  def name_field
    label(class: "flex flex-col gap-1.5") do
      span(class: "text-[11.5px] font-medium text-voodu-text-2 uppercase tracking-[0.04em]") { "Name" }
      input(
        type:  "text",
        name:  "metric_dashboard[name]",
        value: @dashboard.name,
        placeholder: "prod overview",
        autocomplete: "off",
        class: "h-9 px-2.5 border border-voodu-border bg-voodu-surface text-voodu-text text-[13px] placeholder:text-voodu-muted-2 focus:outline-none focus:border-voodu-accent-line"
      )
    end
  end

  # add_panel_row — source + metric pickers (DS dropdowns) + Add.
  # Stacks on narrow viewports, sits inline at vmd+. The dropdown
  # controller owns open/close; dashboard-builder owns the selection.
  def add_panel_row
    div(class: "flex flex-col gap-2 p-3 border border-voodu-border-2 bg-voodu-surface") do
      span(class: "text-[11.5px] font-medium text-voodu-text-2 uppercase tracking-[0.04em]") { "Add panel" }

      div(class: "flex flex-col vmd:flex-row gap-2") do
        source_picker
        metric_picker
        add_button
      end
    end
  end

  # source_picker — static menu (Host + each workload), rendered server
  # side. Selecting one updates the trigger label and repopulates the
  # metric picker for that source's kind.
  def source_picker
    div(class: "vmd:flex-1 min-w-0 relative", data: { controller: "dropdown" }) do
      picker_trigger("Host (system)", :sourceLabel)
      div(hidden: true, data: { dropdown_target: "menu" }, class: menu_classes) do
        source_option({ scope_kind: "host", label: "host" }, "Host (system)")
        workloads.each { |w| source_option(w, "#{w[:label]} · #{w[:kind]}") }
      end
    end
  end

  # metric_picker — menu filled by the builder controller from the
  # catalog whenever the source changes (the offered metrics depend on
  # the source's kind).
  def metric_picker
    div(class: "vmd:flex-1 min-w-0 relative", data: { controller: "dropdown" }) do
      picker_trigger("Select metric", :metricLabel)
      div(hidden: true, data: { dropdown_target: "menu", dashboard_builder_target: "metricMenu" }, class: menu_classes)
    end
  end

  def picker_trigger(label_text, target)
    button(
      type:  "button",
      data:  { action: "click->dropdown#toggle" },
      class: "inline-flex items-center gap-2 px-2.5 h-9 w-full border border-voodu-border bg-voodu-surface text-voodu-text hover:bg-voodu-surface-2"
    ) do
      span(
        class: "min-w-0 truncate flex-1 text-left text-[12.5px] text-voodu-text",
        data:  { dashboard_builder_target: target }
      ) { label_text }
      render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 text-voodu-muted shrink-0")
    end
  end

  def source_option(src, text)
    button(
      type:  "button",
      data:  { action: "click->dashboard-builder#selectSource click->dropdown#close", source: src.to_json },
      class: option_classes
    ) { text }
  end

  def add_button
    button(
      type:  "button",
      data:  { action: "click->dashboard-builder#add" },
      class: "inline-flex items-center justify-center gap-1.5 px-3 h-9 border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 text-[12.5px] font-medium hover:bg-voodu-accent/20 shrink-0"
    ) do
      render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
      span { "Add" }
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
      div(data: { dashboard_builder_target: "list" }, class: "flex flex-col gap-1.5")
      div(
        data:  { dashboard_builder_target: "empty" },
        class: "text-[11.5px] text-voodu-muted px-1"
      ) { "No panels yet — pick a source + metric above and press Add." }
    end
  end

  def hidden_panels_input
    input(
      type: "hidden",
      name: "metric_dashboard[panels]",
      data: { dashboard_builder_target: "hidden" }
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
        type:  "submit",
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
        scope:      (p["scope"] || p[:scope]).to_s,
        name:       (p["resource_name"] || p[:resource_name]).to_s,
        kind:       (p["kind"] || p[:kind]).to_s.presence || "pod",
        label:      (p["resource_name"] || p[:resource_name]).to_s
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
      scope_kind = kind == "host" ? "host" : "pod"
      acc[kind]  = MetricsPageData.metric_catalog_for(scope_kind, kind).map { |s| spec_json(s) }
    end.to_json
  end

  def existing_panels_json
    Array(@dashboard.panels).to_json
  end

  def spec_json(spec)
    {
      metric:  spec[:metric],
      scale:   spec[:scale].to_s,
      label:   spec[:label],
      color:   spec[:color],
      unit:    spec[:unit].to_s,
      section: spec[:section].to_s
    }
  end
end
