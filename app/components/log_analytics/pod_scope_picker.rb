# frozen_string_literal: true

# Components::LogAnalytics::PodScopePicker — pod scope for the analytics
# filter bar, using the design-system dropdown (the `dropdown` Stimulus
# controller + the ScopePicker visual language) instead of a native
# <select> (whose OS-rendered menu doesn't match the DS).
#
# Unlike Components::UI::ScopePicker (whose rows are <a href> that
# navigate), this one lives INSIDE the filter <form>: each row is a
# button that sets a hidden `pods[]` input and re-runs the query
# (log-analytics#selectPod → requestSubmit), so the active q / range /
# custom dates are preserved and the URL stays bookmarkable. The look
# (trigger + grouped menu + option rows + check on active) mirrors the
# DS picker so the two read as the same control.
#
#   selected: the active container name, or nil for "All pods".
class Components::LogAnalytics::PodScopePicker < Components::Base
  def initialize(pods:, selected: nil)
    @pods     = Array(pods)
    @selected = selected.presence
  end

  def view_template
    div(class: "relative", data: { controller: "dropdown" }) do
      input(type: "hidden", name: "pods[]", value: @selected, data: { log_analytics_target: "podInput" })
      trigger_button
      menu
    end
  end

  private

  def selected_label
    return "All pods" if @selected.nil?

    pod = @pods.find { |p| pod_name(p) == @selected }
    pod ? pod_label(pod) : @selected
  end

  def trigger_button
    button(
      type: "button",
      data: { action: "click->dropdown#toggle" },
      class: "inline-flex items-center gap-2 px-2.5 h-8 min-w-[150px] vmd:max-w-[200px] border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] hover:bg-voodu-surface-2"
    ) do
      render Icon::CubeOutline.new(class: "w-3 h-3 shrink-0 text-voodu-muted")
      span(class: "min-w-0 truncate font-voodu-mono text-voodu-text", data: { log_analytics_target: "podLabel" }) { selected_label }
      div(class: "flex-1")
      render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 text-voodu-muted shrink-0")
    end
  end

  def menu
    div(
      hidden: true,
      data: { dropdown_target: "menu" },
      class: "absolute left-0 top-[calc(100%+4px)] z-30 min-w-[220px] max-w-[320px] max-h-[360px] overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface-2 shadow-2xl"
    ) do
      option_row(value: "", label: "All pods", icon: :Squares2x2Outline, active: @selected.nil?)
      pod_options
    end
  end

  def pod_options
    return if @pods.empty?

    section_label("Pods")
    @pods.each do |pod|
      name = pod_name(pod)
      next if name.blank?

      option_row(value: name, label: pod_label(pod), meta: name, status: pod_status(pod), active: @selected == name)
    end
  end

  def section_label(text)
    div(class: "px-3 py-1.5 text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted bg-voodu-bg-2 border-y border-voodu-border") { text }
  end

  def option_row(value:, label:, active:, icon: nil, status: nil, meta: nil)
    button(
      type: "button",
      data: {
        action: "click->log-analytics#selectPod click->dropdown#close",
        pod:    value,
        label:  label
      },
      class: tokens(
        "flex items-center gap-2.5 w-full px-3 py-2 min-h-[36px] text-left",
        active ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text hover:bg-voodu-hover"
      )
    ) do
      leading(icon, status)

      div(class: "min-w-0 flex-1 flex flex-col") do
        span(class: tokens("font-voodu-mono text-[12px] truncate", active ? "font-semibold text-voodu-accent-2" : "font-medium text-voodu-text")) { label }
        if meta.present?
          span(class: "text-[10px] text-voodu-muted font-voodu-mono truncate") { meta }
        end
      end

      render Icon::CheckOutline.new(class: "w-3 h-3 text-voodu-accent-2 shrink-0") if active
    end
  end

  def leading(icon, status)
    span(class: "inline-flex shrink-0", style: "color: var(--voodu-muted);") do
      if icon
        render Icon.const_get(icon).new(class: "w-3 h-3")
      else
        render Components::UI::StatusDot.new(status: (status.presence || "running").to_sym, size: 6)
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
