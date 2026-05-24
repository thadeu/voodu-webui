# frozen_string_literal: true

# Components::Logs::PodPicker — dropdown to switch which pod's logs
# the viewer tails. Mirrors Components::Metrics::ScopePicker visually
# and behaviourally; the Logs surface only has two effective scopes:
#
#   - "all"  → /<key>/logs               (multi-source fan-out)
#   - "pod"  → /<key>/logs/<container>   (single-pod tail)
#
# The host-level scope that ScopePicker offers doesn't apply here
# (the host doesn't ship application logs; only pods do). "All pods"
# fills the same row as the host option does in ScopePicker so the
# muscle memory between the two pages stays intact.
class Components::Logs::PodPicker < Components::Base
  # active_pod — the container name currently being tailed, or nil
  # for the multi-source view. The trigger button + the selected
  # row in the dropdown reflect this.
  def initialize(active_pod:, pods: [])
    @active_pod = active_pod
    @pods       = Array(pods)
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
        if @active_pod.present?
          span(class: "text-voodu-muted") { "pod " }
          span(class: "font-voodu-mono text-voodu-text") { @active_pod }
        else
          span(class: "font-voodu-mono text-voodu-text") { "all pods" }
        end
      end
      div(class: "flex-1")
      render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 text-voodu-muted")
    end
  end

  def kind_icon
    if @active_pod.present?
      render Icon::CubeOutline.new(class: "w-3 h-3")
    else
      render Icon::Squares2x2Outline.new(class: "w-3 h-3")
    end
  end

  def menu
    div(
      hidden: true,
      data: { dropdown_target: "menu" },
      # scrollbar-hidden keeps the menu native-macOS-feeling:
      # still scrolls via wheel/trackpad/keyboard, no visible track
      # stealing pixels inside the already-narrow 360px column.
      class: "absolute left-0 top-[calc(100%+4px)] z-30 min-w-[280px] max-w-[360px] max-h-[400px] overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface-2 shadow-2xl"
    ) do
      all_option
      pod_groups
    end
  end

  # all_option — the equivalent of ScopePicker's "host" row.
  # Selecting it drops to the multi-source view.
  def all_option
    section_label("ALL")
    pod_option(
      href:   helpers.logs_path,
      active: @active_pod.blank?,
      title:  "all pods",
      meta:   "#{@pods.size} #{@pods.size == 1 ? "source" : "sources"}",
      icon:   :all
    )
  end

  def pod_groups
    return if @pods.empty?

    by_scope = @pods
      .group_by { |p| p[:scope] || p["scope"] || "(default)" }
      .sort_by  { |k, _| k.to_s }

    by_scope.each do |scope_name, pods|
      section_label(scope_name.to_s)

      pods.each do |p|
        container = p[:name] || p["name"]
        resource  = p[:resource_name] || p["resource_name"]
        replica   = p[:replica_id] || p["replica_id"]
        image     = p[:image] || p["image"]
        status    = (p[:status] || p["status"] || "running").to_s.to_sym

        title = replica.present? ? "#{resource}.#{replica}" : (resource || container)

        pod_option(
          href:   helpers.pod_logs_path(name: container),
          active: @active_pod == container,
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

  def pod_option(href:, active:, title:, meta:, status: :running, icon: :status)
    a(
      href: href,
      data: { turbo: false },
      class: tokens(
        "flex items-center gap-2.5 w-full px-3 py-2 min-h-[38px] text-left",
        active ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text hover:bg-[#ffffff08]"
      )
    ) do
      span(class: "inline-flex shrink-0", style: "color: var(--voodu-muted);") do
        if icon == :all
          render Icon::Squares2x2Outline.new(class: "w-3 h-3")
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
end
