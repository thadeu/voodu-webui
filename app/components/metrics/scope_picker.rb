# frozen_string_literal: true

# Components::Metrics::ScopePicker — dropdown picking what to chart.
# Two source types ("kind=host|pod"):
#
#   - host:   the controller VM (CPU/Mem/Disk/Net of the whole box)
#   - pod:    a specific container, grouped by scope under the host
#
# Form-driven (no JS state machine): selecting a row submits a GET
# to /metrics?scope_kind=...&scope_id=... — the controller reads
# the params, fetches the right series, re-renders.
#
# Reuses Components::UI::Dropdown's Stimulus controller for the
# open/close + click-outside behaviour (existing controller in
# app/javascript/controllers/dropdown_controller.js).
#
# Markup mirrors design-webui-inspiration/pages-metrics.jsx
# (ScopePicker, lines 401-498) — same visual rhythm, just driven
# by Rails params instead of React state.
class Components::Metrics::ScopePicker < Components::Base
  def initialize(scope_kind:, scope_id:, current_island:, pods: [])
    @scope_kind     = scope_kind         # "host" | "pod"
    @scope_id       = scope_id           # host name or pod container name
    @current_island = current_island
    @pods           = Array(pods)
  end

  def view_template
    div(class: "relative", data: { controller: "dropdown" }) do
      trigger_button
      menu
    end
  end

  private

  def trigger_button
    button(
      type: "button",
      data: { action: "click->dropdown#toggle" },
      class: "inline-flex items-center gap-2 px-2.5 h-8 min-w-[180px] border border-voodu-border bg-voodu-surface text-voodu-text text-[12.5px] hover:bg-voodu-surface-2"
    ) do
      kind_icon
      span(class: "min-w-0 truncate") do
        span(class: "text-voodu-muted") { "#{@scope_kind} " }
        span(class: "font-voodu-mono text-voodu-text") { display_id }
      end
      div(class: "flex-1")
      render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 text-voodu-muted")
    end
  end

  def kind_icon
    if @scope_kind == "host"
      render Icon::CpuChipOutline.new(class: "w-3 h-3")
    else
      render Icon::CubeOutline.new(class: "w-3 h-3")
    end
  end

  def display_id
    return @scope_id.to_s if @scope_id.present?
    return @current_island&.name || "host" if @scope_kind == "host"

    "(unknown)"
  end

  def menu
    div(
      hidden: true,
      data: { dropdown_target: "menu" },
      class: "absolute left-0 top-[calc(100%+4px)] z-30 min-w-[280px] max-w-[360px] max-h-[400px] overflow-auto border border-voodu-border-2 bg-voodu-surface-2 shadow-2xl"
    ) do
      host_group
      pod_groups
    end
  end

  def host_group
    section_label("HOST")

    host_name = @current_island&.name || "host"
    active    = @scope_kind == "host"

    scope_option(
      href:   metrics_url(kind: "host", id: host_name),
      active: active,
      title:  host_name,
      meta:   "#{@current_island&.host || "—"} · #{@pods.size} pods",
      icon:   :cpu
    )
  end

  def pod_groups
    return if @pods.empty?

    by_scope = @pods.group_by { |p| p[:scope] || p["scope"] || "(default)" }.sort_by { |k, _| k.to_s }

    by_scope.each do |scope_name, pods|
      section_label(scope_name.to_s)

      pods.each do |p|
        container = p[:name] || p["name"]
        resource  = p[:resource_name] || p["resource_name"]
        replica   = p[:replica_id] || p["replica_id"]
        image     = p[:image] || p["image"]
        status    = (p[:status] || p["status"] || "running").to_s.to_sym

        title = replica.present? ? "#{resource}.#{replica}" : (resource || container)

        scope_option(
          href:   metrics_url(kind: "pod", id: container),
          active: @scope_kind == "pod" && @scope_id == container,
          title:  title,
          meta:   image,
          status: status,
          icon:   :status
        )
      end
    end
  end

  def section_label(text)
    div(
      class: "px-3 py-1.5 text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted bg-voodu-bg-2 border-y border-voodu-border"
    ) { text }
  end

  def scope_option(href:, active:, title:, meta:, status: :running, icon: :status)
    a(
      href: href,
      data: { turbo: false },
      class: tokens(
        "flex items-center gap-2.5 w-full px-3 py-2 min-h-[38px] text-left",
        active ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text hover:bg-[#ffffff08]"
      )
    ) do
      span(class: "inline-flex shrink-0", style: "color: var(--voodu-muted);") do
        if icon == :cpu
          render Icon::CpuChipOutline.new(class: "w-3 h-3")
        else
          render Components::UI::StatusDot.new(status: status, size: 6)
        end
      end

      div(class: "min-w-0 flex-1 flex flex-col") do
        span(
          class: tokens(
            "font-voodu-mono text-[12.5px] truncate",
            active ? "font-semibold text-voodu-accent-2" : "font-medium text-voodu-text"
          )
        ) { title }
        span(class: "text-[10.5px] text-voodu-muted font-voodu-mono truncate") { meta.to_s }
      end

      if active
        render Icon::CheckOutline.new(class: "w-3 h-3 text-voodu-accent-2 shrink-0")
      end
    end
  end

  # metrics_url — preserves the current `range` param if present
  # so switching scope doesn't reset the operator's range pill.
  def metrics_url(kind:, id:)
    params = helpers.request.query_parameters.merge(scope_kind: kind, scope_id: id)
    "#{helpers.metrics_path}?#{params.to_query}"
  end
end
