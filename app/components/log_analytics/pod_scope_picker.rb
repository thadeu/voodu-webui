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

  # Full-width trigger — matches the query editor below it, so the closed
  # control fills the drawer instead of sitting stubby on the left.
  def trigger_button
    button(
      type: "button",
      data: { action: "click->dropdown#toggle" },
      class: "flex items-center gap-2 w-full px-2.5 h-8 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] hover:bg-voodu-surface-2"
    ) do
      render Icon::CubeOutline.new(class: "w-3 h-3 shrink-0 text-voodu-muted")
      span(class: "min-w-0 truncate font-voodu-mono text-voodu-text", data: { log_analytics_target: "podLabel" }) { trigger_label }
      div(class: "flex-1")
      render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 text-voodu-muted shrink-0")
    end
  end

  # menu — a flex COLUMN with a fixed header + a scrolling pod list + a fixed
  # Apply footer. Capping the whole popover and scrolling only the middle is
  # what keeps Apply always reachable (it used to scroll off the bottom).
  # `left-0 right-0` stretches the popover to the FULL width of the filter
  # section (it adapts as the drawer is resized) instead of a cramped fixed
  # 260px — the trigger above stays narrow, the menu goes wide. Capped so it
  # never sprawls on a hugely-widened drawer.
  def menu
    div(
      hidden: true,
      data:  { dropdown_target: "menu" },
      class: "absolute left-0 right-0 top-[calc(100%+4px)] z-40 max-w-[640px] flex flex-col max-h-[360px] border border-voodu-border-2 bg-voodu-surface shadow-2xl"
    ) do
      list_header
      pod_list
      footer
    end
  end

  # list_header — the "PODS" label + a select-all / clear toggle. Replaces the
  # old exclusive "All pods" row (redundant: an empty selection already means
  # "all pods" server-side).
  def list_header
    div(class: "shrink-0 flex items-center justify-between gap-2 px-3 py-2 bg-voodu-bg-2 border-b border-voodu-border") do
      span(class: "text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted") { "Pods" }
      select_all_button
    end
  end

  # select_all_button — toggles every pod on/off. The label flips to "Clear"
  # once all are selected (log-analytics#refreshPodScope keeps it in sync).
  def select_all_button
    all = @pods.any? && @pods.all? { |p| @selected.include?(pod_name(p)) }
    button(
      type: "button",
      data: { action: "click->log-analytics#toggleAllPods" },
      "aria-label": "Select all pods or clear the selection",
      class: "inline-flex items-center gap-1 px-1.5 h-5 text-[10.5px] font-medium text-voodu-accent-2 hover:text-voodu-accent transition-colors"
    ) do
      render Icon::CheckCircleOutline.new(class: "w-3.5 h-3.5")
      span(data: { log_analytics_target: "selectAllLabel" }) { all ? "Clear" : "Select all" }
    end
  end

  # Two columns from vmd: up (the wide menu has room); single column on a
  # narrow viewport so mono pod names don't get crushed.
  def pod_list
    div(class: "flex-1 min-h-0 overflow-auto scrollbar-hidden grid grid-cols-1 vmd:grid-cols-2") do
      if @pods.empty?
        div(class: "vmd:col-span-2 px-3 py-4 text-center text-[11.5px] text-voodu-muted") { "No pods reporting." }
      else
        @pods.each do |pod|
          name = pod_name(pod)
          next if name.blank?

          pod_row(pod, name)
        end
      end
    end
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

  # footer — fixed at the bottom (shrink-0), so Apply is always visible no
  # matter how long the pod list scrolls.
  def footer
    div(class: "shrink-0 border-t border-voodu-border") do
      button(
        type: "button",
        data: { action: "click->log-analytics#applyPods click->dropdown#close" },
        class: "flex items-center justify-center gap-1.5 w-full px-3 py-2.5 min-h-[40px] text-[12px] font-semibold text-voodu-accent-2 hover:bg-voodu-accent-dim"
      ) do
        render Icon::CheckOutline.new(class: "w-3 h-3 shrink-0")
        span { "Apply" }
      end
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
