# frozen_string_literal: true

# Views::Metrics::Index — the /metrics page.
#
# Layout mirrors design-webui-inspiration/pages-metrics.jsx
# MetricsPage (lines 590-707): page head with scope subtitle +
# Logs/Open pod/Refresh actions, toolbar (scope picker + range
# pills), optional replica chips, 2x2 grid of chart cards.
class Views::Metrics::Index < Views::Base
  def initialize(current_path:, islands: [], current_island: nil, data: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @data           = data
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path,
      islands: @islands,
      current_island: @current_island
    ) do
      if @current_island.nil?
        render Components::UI::NoIslandState.new
      else
        body
      end
    end
  end

  private

  def body
    div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
      page_head
      toolbar
      replica_chips
      chart_grid
    end
  end

  def page_head
    div(class: "flex flex-wrap items-end justify-between gap-3 vmd:gap-4") do
      div(class: "min-w-0") do
        h1(class: "text-[22px] font-semibold text-voodu-text tracking-tight") { "Metrics" }
        page_sub
      end

      div(class: "flex items-center gap-2 shrink-0") do
        pod_actions if pod_scope?
        refresh_btn
      end
    end
  end

  # page_sub — "pod x.aaaa · image:tag · last 1h · ● auto-refresh"
  # Mirrors the inspiration's scopeSubtitle + metadata strip.
  def page_sub
    div(class: "flex flex-wrap items-center gap-2.5 mt-1 text-[12.5px] text-voodu-muted") do
      scope_subtitle
      dot_sep
      span do
        plain "last "
        span(class: "font-voodu-mono text-voodu-text-2") { @data&.range || "1h" }
      end
      dot_sep
      auto_refresh_indicator
    end
  end

  def scope_subtitle
    if @data&.scope_kind == "pod" && (pod = @data.pod_record)
      span do
        plain "pod "
        span(class: "font-voodu-mono text-voodu-text-2") { @data.scope_id }
        plain " · "
        span(class: "font-voodu-mono") { pod["image"] }
      end
    else
      span do
        plain "host "
        span(class: "font-voodu-mono text-voodu-text-2") { @current_island.name }
      end
    end
  end

  def auto_refresh_indicator
    span(class: "inline-flex items-center gap-1.5") do
      span(
        class: "inline-block rounded-full animate-voodu-pulse",
        style: "width: 6px; height: 6px; background: var(--voodu-green); box-shadow: 0 0 0 3px color-mix(in srgb, var(--voodu-green) 18%, transparent);"
      )
      span { "auto-refresh" }
    end
  end

  def dot_sep
    span(
      class: "inline-block w-[3px] h-[3px] rounded-full bg-voodu-border-2",
      aria: { hidden: "true" }
    )
  end

  def pod_scope?
    @data&.scope_kind == "pod" && @data.scope_id.present?
  end

  # pod_actions — Logs + Open pod buttons only when a pod is the
  # current scope. Matches the inspiration's conditional render.
  def pod_actions
    a(
      href: helpers.pod_logs_path(name: @data.scope_id),
      class: btn_secondary_classes
    ) do
      render Icon::DocumentTextOutline.new(class: "w-3.5 h-3.5")
      span { "Logs" }
    end

    a(
      href: helpers.pod_path(name: @data.scope_id),
      class: btn_secondary_classes
    ) do
      render Icon::ArrowTopRightOnSquareOutline.new(class: "w-3.5 h-3.5")
      span { "Open pod" }
    end
  end

  def refresh_btn
    params_for_refresh = helpers.request.query_parameters.merge(refresh: 1)
    a(
      href: "#{helpers.metrics_path}?#{params_for_refresh.to_query}",
      data: { turbo: false },
      class: btn_secondary_classes
    ) do
      render Icon::ArrowPathOutline.new(class: "w-3.5 h-3.5")
      span { "Refresh" }
    end
  end

  def btn_secondary_classes
    "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
  end

  def toolbar
    div(class: "flex items-center gap-2.5 flex-wrap") do
      render Components::Metrics::ScopePicker.new(
        scope_kind:     @data&.scope_kind || "host",
        scope_id:       @data&.scope_id,
        current_island: @current_island,
        pods:           @data&.all_pods || []
      )
      render Components::Metrics::RangePicker.new(range: @data&.range || "1h")
    end
  end

  def replica_chips
    return unless pod_scope?

    render Components::Metrics::ReplicaChips.new(
      active_container: @data.scope_id,
      siblings:         @data.sibling_replicas
    )
  end

  # chart_grid — 1 column on narrow viewports, 2 columns at vmd+.
  # Host scope shows 3 cards (CPU/Mem/Disk — host net was removed
  # in W7); pod scope shows 4 (CPU/Mem/Rx/Tx). Grid auto-wraps
  # cleanly either way.
  def chart_grid
    return if @data.nil?

    div(
      class: "grid grid-cols-1 vmd:grid-cols-2 gap-3"
    ) do
      @data.charts.each do |c|
        render Components::Metrics::ChartCard.new(
          label:    c[:label],
          color:    c[:color],
          unit:     c[:unit],
          points:   c[:points],
          range_ms: @data.range_ms,
          current:  c[:current]
        )
      end
    end
  end
end
