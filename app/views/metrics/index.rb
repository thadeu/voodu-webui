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
      # chart_grid renders BOTH resource and HTTP charts inside the
      # turbo-frame. HTTP must NOT live as a sibling outside the
      # frame — when the polling tick fetches Views::Metrics::Frame,
      # that response renders HTTP inside the frame too, and a
      # sibling rendering would survive as a duplicate on the page
      # (the bug operators saw as "two HTTP blocks" for a 1-replica
      # web pod).
      chart_grid
    end
  end

  def page_head
    render(
      Components::UI::PageHeader.new(title: "Metrics")
        .with_subtitle { page_sub }
        .with_actions do
          pod_actions if pod_scope?
          refresh_btn
        end
    )
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
  # pod_actions — Logs + Open pod for the active scope. Both wrap
  # the destination in a right-side Drawer so the operator can peek
  # without losing chart context. Cmd-click still opens the full
  # page in a new tab (Components::UI::Drawer's trigger is an
  # anchor, not a button — see its docs).
  def pod_actions
    render(Components::UI::Drawer.new(
      title:    "Logs · #{@data.scope_id}",
      src:      "#{pod_logs_path(name: @data.scope_id)}?embed=1",
      open_url: pod_logs_path(name: @data.scope_id),
      trigger_attrs: { class: btn_secondary_classes }
    )) do
      render Icon::DocumentTextOutline.new(class: "w-3.5 h-3.5")
      span { "Logs" }
    end

    # Pod drawer defaults narrower (30vw vs 40vw for Logs) — the
    # drawer-mode Pods::Show drops the duplicate stat cards, so it
    # has less to show; a thinner drawer keeps more of the Metrics
    # page visible at the same time. Resizable handle still lets
    # the operator override either way.
    render(Components::UI::Drawer.new(
      title:    "Pod · #{@data.scope_id}",
      src:      "#{pod_path(name: @data.scope_id)}?embed=1",
      open_url: pod_path(name: @data.scope_id),
      width:    "70vw",
      trigger_attrs: { class: btn_secondary_classes }
    )) do
      render Icon::ArrowTopRightOnSquareOutline.new(class: "w-3.5 h-3.5")
      span { "Open pod" }
    end
  end

  def refresh_btn
    params_for_refresh = request.query_parameters.merge(refresh: 1)
    a(
      href: "#{metrics_path}?#{params_for_refresh.to_query}",
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
      render Components::Metrics::PodPicker.new(
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
  #
  # Wrapped in `polling_controller` + `turbo_frame_tag` so the
  # `auto-refresh` chip is honest:
  #
  #   - Initial pageload renders the grid inline (chart appears
  #     immediately, no fetch round-trip blocked on Turbo).
  #   - polling_controller.js ticks every 30s and calls
  #     `frame.reload()`, which refetches the frame's src (the
  #     current URL with all query params preserved).
  #   - MetricsController detects the `Turbo-Frame` header and
  #     responds with Views::Metrics::Frame (layout: false), which
  #     is just THIS grid inside a matching `<turbo-frame>` tag.
  #   - Turbo atomically swaps the frame contents — scroll position,
  #     range pill, scope picker state all preserved.
  #
  # 30s cadence chosen to align with the warehouse sync tick
  # (MetricsSyncIslandJob runs every 30s). Polling faster wouldn't
  # see fresher data; polling slower would lose responsiveness
  # without saving meaningful work.
  def chart_grid
    return if @data.nil?

    div(
      data: {
        controller: "polling",
        polling_interval_value: "30000"
      }
    ) do
      # `src` is the current URL preserving query params (scope,
      # range, refresh marker). On reload Turbo refetches the same
      # URL with the Turbo-Frame header set, which the controller
      # uses to short-circuit to the Frame view.
      turbo_frame_tag("metrics-charts", src: current_request_url) do
        # Same structure Views::Metrics::Frame renders on each poll
        # tick. Keeping both surfaces identical means the initial
        # pageload and the post-tick swap show the same DOM — no
        # flicker, no duplication, no "HTTP section disappears
        # for one tick" race.
        div(class: "flex flex-col gap-4 vmd:gap-5") do
          render_chart_cards(@data.charts)
          http_section if @data.ingress_eligible?
        end
      end
    end
  end

  # http_section — HTTP heading + chart grid. Called from INSIDE the
  # turbo-frame block (both here and in Views::Metrics::Frame) so the
  # section participates in the polling swap. Rendering it as a
  # sibling of the frame would duplicate after the first tick because
  # the Frame response also contains it.
  def http_section
    div(class: "flex flex-col gap-2.5") do
      h2(
        class: "text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted flex items-center gap-2"
      ) do
        span { "HTTP" }
        span(class: "flex-1 h-px bg-voodu-border")
        span(class: "font-normal text-voodu-muted-2 normal-case tracking-normal") { "ingress · same range" }
      end

      render_chart_cards(@data.http_charts)
    end
  end

  # render_chart_cards — shared block for both grids; identical
  # layout class + ChartCard wiring. Extracted so chart_grid and
  # http_chart_grid don't drift on grid columns / gap.
  #
  # `expand_url` is the per-card URL that the maximize button
  # opens via the chart-expand Stimulus controller. We build it
  # here (not inside ChartCard) so the component stays
  # presentation-only — knowing how to talk to /metrics/chart is
  # the parent view's job, since it owns the helpers.
  def render_chart_cards(charts)
    div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-3") do
      charts.each do |c|
        render Components::Metrics::ChartCard.new(
          label:      c[:label],
          color:      c[:color],
          unit:       c[:unit],
          points:     c[:points],
          range_ms:   @data.range_ms,
          current:    c[:current],
          expand_url: expand_url_for(c),
          metric:     c[:metric]
        )
      end
    end
  end

  # expand_url_for — builds the URL the maximize button opens.
  # Echoes the parent page's scope_kind/scope_id/range so the
  # modal starts at the same view the operator is looking at,
  # then layers on metric/scale/label/color/unit so the modal
  # endpoint can rebuild THIS single chart (not the whole grid).
  def expand_url_for(chart)
    qp = request.query_parameters
    params = {
      scope_kind: qp[:scope_kind] || @data&.scope_kind,
      scope_id:   qp[:scope_id]   || @data&.scope_id,
      range:      qp[:range]      || @data&.range || "1h",
      metric:     chart[:metric],
      scale:      chart[:scale],
      label:      chart[:label],
      color:      chart[:color],
      unit:       chart[:unit]
    }.compact

    "#{metrics_chart_path}?#{params.to_query}"
  end

  # current_request_url — request path + query string. Used as the
  # turbo-frame `src` so the polling reload refetches the exact same
  # scope/range/refresh the operator is viewing. Re-serialising via
  # `to_query` instead of `request.original_url` because the latter
  # carries the host+port which would force a CORS-like fetch in
  # local dev with non-default ports.
  def current_request_url
    qs = request.query_parameters.to_query
    qs.present? ? "#{request.path}?#{qs}" : request.path
  end
end
