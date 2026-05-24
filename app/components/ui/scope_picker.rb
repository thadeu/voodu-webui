# frozen_string_literal: true

# Components::UI::ScopePicker — generic "pick one of these (grouped)"
# dropdown. Used by both:
#
#   - Components::Metrics::PodPicker → host vs pod for charts
#   - Components::Logs::PodPicker    → all pods vs one pod for tail
#
# Both surfaces share the same visual rhythm: a min-w-180 trigger
# button with an icon + selected-value label, opening into a 360px
# panel with a "primary" section (HOST / ALL) and zero-or-more
# pod groups (grouped by scope, each pod row shows name + image +
# status dot).
#
# This component owns:
#   - The DOM shape (trigger + menu)
#   - The Dropdown stimulus controller wiring (open/close/outside-click)
#   - The scrollbar-hidden + sizing constants (so changes propagate)
#
# Callers own:
#   - URL building (path conventions differ between surfaces)
#   - "Which row is active" determination (state lives upstream)
#   - The "primary" section label + icon (HOST vs ALL)
#
# DATA SHAPES
#
#   trigger:         { icon: :Symbol, prefix: "kind ", value: "name" }
#   primary_section: { label: "HOST", option: option_hash } | nil
#   pod_sections:    [ { label: "scope", options: [option_hash, ...] }, ... ]
#
#   option_hash:
#     {
#       title:  "crawler1.33a5",
#       meta:   "clowk-lp-web:latest",
#       href:   "/<key>/logs/crawler1.33a5",
#       active: true | false,
#       # one of:
#       icon:   :CpuChipOutline,        # host / "all" rows
#       status: :running                 # pod rows (dot)
#     }
class Components::UI::ScopePicker < Components::Base
  def initialize(trigger:, primary_section: nil, pod_sections: [])
    @trigger         = trigger
    @primary_section = primary_section
    @pod_sections    = Array(pod_sections)
  end

  def view_template
    div(class: "relative", data: { controller: "dropdown" }) do
      trigger_button
      menu
    end
  end

  private

  def trigger_button
    icon_klass = Icon.const_get(@trigger.fetch(:icon))

    button(
      type: "button",
      data: { action: "click->dropdown#toggle" },
      class: "inline-flex items-center gap-2 px-2.5 h-8 min-w-[180px] border border-voodu-border bg-voodu-surface text-voodu-text text-[12.5px] hover:bg-voodu-surface-2"
    ) do
      render icon_klass.new(class: "w-3 h-3")

      span(class: "min-w-0 truncate") do
        if @trigger[:prefix].present?
          span(class: "text-voodu-muted") { @trigger[:prefix] }
        end
        span(class: "font-voodu-mono text-voodu-text") { @trigger.fetch(:value) }
      end

      div(class: "flex-1")
      render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 text-voodu-muted")
    end
  end

  def menu
    div(
      hidden: true,
      data: { dropdown_target: "menu" },
      # scrollbar-hidden — native-macOS feel; the 280–360px panel
      # can't afford to lose 10px to a permanent scrollbar track.
      class: "absolute left-0 top-[calc(100%+4px)] z-30 min-w-[280px] max-w-[360px] max-h-[400px] overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface-2 shadow-2xl"
    ) do
      render_primary_section
      render_pod_sections
    end
  end

  def render_primary_section
    return if @primary_section.nil?

    section_label(@primary_section.fetch(:label))
    option_row(@primary_section.fetch(:option))
  end

  def render_pod_sections
    @pod_sections.each do |section|
      section_label(section.fetch(:label))
      Array(section[:options]).each { |opt| option_row(opt) }
    end
  end

  def section_label(text)
    div(
      class: "px-3 py-1.5 text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted bg-voodu-bg-2 border-y border-voodu-border"
    ) { text }
  end

  # option_row — the clickable row. Renders either an explicit
  # `icon:` (host/all rows) or a StatusDot (pod rows), based on
  # which key the caller provided.
  def option_row(opt)
    active = opt[:active]
    title  = opt.fetch(:title)
    meta   = opt[:meta].to_s
    href   = opt.fetch(:href)

    a(
      href: href,
      data: { turbo: false },
      class: tokens(
        "flex items-center gap-2.5 w-full px-3 py-2 min-h-[38px] text-left",
        active ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text hover:bg-[#ffffff08]"
      )
    ) do
      leading_indicator(opt)

      div(class: "min-w-0 flex-1 flex flex-col") do
        span(
          class: tokens(
            "font-voodu-mono text-[12.5px] truncate",
            active ? "font-semibold text-voodu-accent-2" : "font-medium text-voodu-text"
          )
        ) { title }
        span(class: "text-[10.5px] text-voodu-muted font-voodu-mono truncate") { meta }
      end

      if active
        render Icon::CheckOutline.new(class: "w-3 h-3 text-voodu-accent-2 shrink-0")
      end
    end
  end

  def leading_indicator(opt)
    span(class: "inline-flex shrink-0", style: "color: var(--voodu-muted);") do
      if opt[:icon]
        render Icon.const_get(opt[:icon]).new(class: "w-3 h-3")
      else
        render Components::UI::StatusDot.new(status: opt[:status] || :running, size: 6)
      end
    end
  end
end
