# frozen_string_literal: true

# Components::LogAnalytics::PodScopePicker — multi-select pod scope for
# the analytics filter bar. Mirrors the metrics dashboard multiselect
# (Views::Metrics::Index#multiselect_row): a left checkbox box +
# data-role check, a surface-2 menu, and a centred accent footer — so it
# reads as the SAME design-system control, not a new pattern.
#
# Difference from metrics: that one navigates to ?pid=…; this lives in
# the filter <form>, so each row wraps a sr-only native checkbox named
# `pods[]` (the form serialises the selection — LogSearchData reads an
# array). The box/check visuals are JS-driven (log-analytics
# #refreshPodScope) exactly like metric-multiselect#refresh.
#
#   selected: array of container names currently in scope ([] = all).
class Components::LogAnalytics::PodScopePicker < Components::Base
  def initialize(pods:, selected: [])
    @pods     = Array(pods)
    @selected = Array(selected).map(&:to_s).reject(&:blank?)
  end

  def view_template
    div(class: "relative", data: { controller: "dropdown" }) do
      trigger_button
      menu
    end
  end

  private

  def trigger_label
    case @selected.size
    when 0 then "All pods"
    when 1 then single_label
    else        "#{@selected.size} pods"
    end
  end

  def single_label
    pod = @pods.find { |p| pod_name(p) == @selected.first }
    pod ? pod_label(pod) : @selected.first
  end

  def trigger_button
    button(
      type: "button",
      data: { action: "click->dropdown#toggle" },
      class: "inline-flex items-center gap-2 px-2.5 h-8 min-w-[150px] vmd:max-w-[220px] border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] hover:bg-voodu-surface-2"
    ) do
      render Icon::CubeOutline.new(class: "w-3 h-3 shrink-0 text-voodu-muted")
      span(class: "min-w-0 truncate font-voodu-mono text-voodu-text", data: { log_analytics_target: "podLabel" }) { trigger_label }
      div(class: "flex-1")
      render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 text-voodu-muted shrink-0")
    end
  end

  def menu
    div(
      hidden: true,
      data:  { dropdown_target: "menu" },
      class: "absolute left-0 top-[calc(100%+4px)] z-40 min-w-[240px] max-w-[calc(100vw-24px)] max-h-[360px] overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface shadow-2xl"
    ) do
      all_pods_row
      div(class: "h-px bg-voodu-border")
      pod_options
      footer
    end
  end

  # all_pods_row — exclusive "show everything": clears the selection and
  # re-runs immediately (mirrors the metrics Host row). Highlighted +
  # checked when nothing is selected.
  def all_pods_row
    active = @selected.empty?
    button(
      type: "button",
      data: { log_analytics_target: "allPods", action: "click->log-analytics#selectAllPods click->dropdown#close" },
      class: tokens(
        "flex items-center gap-2.5 w-full px-3 py-2 min-h-[36px] text-left text-[12.5px]",
        active ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text hover:bg-voodu-hover"
      )
    ) do
      render Icon::Squares2x2Outline.new(class: "w-3.5 h-3.5 shrink-0")
      span(class: "flex-1 truncate") { "All pods" }
      span(data: { role: "check" }, class: tokens("text-voodu-accent-2", active ? nil : "hidden")) do
        render Icon::CheckOutline.new(class: "w-3 h-3")
      end
    end
  end

  def pod_options
    return if @pods.empty?

    section_label("Pods")
    @pods.each do |pod|
      name = pod_name(pod)
      next if name.blank?

      pod_row(pod, name)
    end
  end

  def section_label(text)
    div(class: "px-3 py-1.5 text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted bg-voodu-bg-2 border-y border-voodu-border") { text }
  end

  # pod_row — a label wrapping a sr-only native checkbox (form value) and
  # the metrics-style checkbox box + check (toggled by the controller).
  def pod_row(pod, name)
    selected = @selected.include?(name)
    label(
      class: "flex items-center gap-2.5 w-full px-3 py-2 min-h-[36px] cursor-pointer text-[12.5px] text-voodu-text hover:bg-voodu-hover"
    ) do
      input(
        type:    "checkbox",
        name:    "pods[]",
        value:   name,
        checked: selected,
        class:   "sr-only",
        data:    { log_analytics_target: "podCheckbox", label: pod_label(pod), action: "change->log-analytics#togglePod" }
      )
      checkbox_box(selected)
      render Components::UI::StatusDot.new(status: (pod_status(pod).presence || "running").to_sym, size: 6)
      span(class: "flex-1 min-w-0 font-voodu-mono truncate") { pod_label(pod) }
    end
  end

  def checkbox_box(selected)
    span(
      data:  { role: "checkbox" },
      class: tokens(
        "inline-flex items-center justify-center w-3.5 h-3.5 border shrink-0",
        selected ? "border-voodu-accent-line bg-voodu-accent-dim" : "border-voodu-border"
      )
    ) do
      span(data: { role: "check" }, class: tokens("text-voodu-accent-2", selected ? nil : "hidden")) do
        render Icon::CheckOutline.new(class: "w-2.5 h-2.5")
      end
    end
  end

  def footer
    return if @pods.empty?

    div(class: "h-px bg-voodu-border")
    button(
      type: "button",
      data: { action: "click->log-analytics#applyPods click->dropdown#close" },
      class: "flex items-center justify-center gap-1.5 w-full px-3 py-2 min-h-[38px] text-[12px] font-semibold text-voodu-accent-2 hover:bg-voodu-accent-dim"
    ) do
      render Icon::CheckOutline.new(class: "w-3 h-3 shrink-0")
      span { "Apply" }
    end
  end

  def pod_name(pod)
    (pod[:name] || pod["name"]).to_s
  end

  def pod_label(pod)
    (pod[:resource_name] || pod["resource_name"]).presence || pod_name(pod)
  end

  def pod_status(pod)
    (pod[:status] || pod["status"]).to_s
  end
end
