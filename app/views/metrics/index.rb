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

    # Shared modal scaffold for chart-expand. Rendered ONCE outside
    # the polling turbo-frame so it survives any 30s reload tick
    # without portal hacks. The maximize buttons on each ChartCard
    # trigger /metrics/chart, which returns a turbo_stream targeting
    # this modal's slots (chart-modal-title / chart-modal-body) +
    # the chart_modal_open custom action.
    render Components::Metrics::ChartModal.new if @current_island
  end

  private

  def body
    # auto-refresh controller owns the WHOLE page body so both the
    # cable source (the wrapped <turbo-cable-stream-source>) and the
    # subtitle button (data-action="click->auto-refresh#toggle")
    # share its scope. Storage key is per-island so toggling
    # auto-refresh on one server doesn't bleed into another.
    div(
      class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5",
      data: {
        controller: "auto-refresh",
        auto_refresh_storage_key_value: "voodu:auto-refresh:#{@current_island.id}"
      }
    ) do
      # Subscribe to live ticks broadcast by MetricsSyncIslandJob
      # whenever new samples land in the warehouse for this island.
      # The custom `metrics_tick` Turbo Stream action (see
      # turbo_actions/metrics.js) calls `frame.reload()` on the
      # metrics-charts frame — same refetch the 30s polling tick
      # does, but triggered by real data arrival.
      #
      # Wrapped in a target span so auto_refresh_controller.js can
      # detach / re-attach the underlying <turbo-cable-stream-source>
      # custom element when the operator toggles auto-refresh off.
      # Detaching fires its disconnectedCallback → unsubscribes;
      # re-attaching fires connectedCallback → resubscribes. Same
      # signed-stream-name node is reused (no re-signing roundtrip).
      span(data: { auto_refresh_target: "source" }) do
        turbo_stream_from "metrics-#{@current_island.id}"
      end

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

  # page_sub — "pod x.aaaa · image:tag · last 1h · every 1m · ● auto-refresh"
  # Mirrors the inspiration's scopeSubtitle + metadata strip. The
  # `every Xm` chip is suppressed when the operator hasn't overridden
  # interval (auto) — keeps the subtitle uncluttered for the default
  # path; only shows up when there's something the operator picked.
  def page_sub
    div(class: "flex flex-wrap items-center gap-2.5 mt-1 text-[12.5px] text-voodu-muted") do
      scope_subtitle
      dot_sep
      span do
        plain "last "
        span(class: "font-voodu-mono text-voodu-text-2") { @data&.range || "1h" }
      end
      if @data&.interval && @data.interval != "auto"
        dot_sep
        span do
          plain "every "
          span(class: "font-voodu-mono text-voodu-text-2") { @data.interval }
        end
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

  # auto_refresh_indicator — clickable toggle for the cable
  # subscription. Default ON (green pulsing dot + "auto-refresh");
  # operator click flips to OFF (red static dot + "paused") and
  # detaches the <turbo-cable-stream-source> so the broadcast tick
  # stops reloading the chart frame. State persists per-island via
  # localStorage in auto_refresh_controller.js — operator pauses
  # once during a long debugging session and the page stays paused
  # across reloads / navigations until they un-pause.
  #
  # The dot + label initial styles are SEEDED here (green + "auto-
  # refresh") to match the controller's default; if the operator
  # had paused state in localStorage, the controller flips both
  # within a few ms of mount. Brief flash is acceptable — the
  # alternative (server-side cookie) costs more than it saves.
  def auto_refresh_indicator
    button(
      type:  "button",
      title: "Toggle auto-refresh",
      data:  { action: "click->auto-refresh#toggle" },
      class: "inline-flex items-center gap-1.5 cursor-pointer hover:opacity-80 transition-opacity"
    ) do
      span(
        data:  { auto_refresh_target: "dot" },
        class: "inline-block rounded-full animate-voodu-pulse",
        style: "width: 6px; height: 6px; background: var(--voodu-green); box-shadow: 0 0 0 3px color-mix(in srgb, var(--voodu-green) 18%, transparent);"
      )
      span(data: { auto_refresh_target: "label" }) { "realtime" }
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
      title:     "Logs · #{@data.scope_id}",
      src:       "#{pod_logs_path(name: @data.scope_id)}?embed=1",
      open_url:  pod_logs_path(name: @data.scope_id),
      # Logs are content-heavy — allow drag up to 85vw for wide
      # payloads. Same rationale as Components::Pods::Header
      # #view_logs_btn.
      max_width: "85vw",
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
      render Components::Metrics::IntervalPicker.new(
        current:      @data&.interval || "auto",
        base_path:    metrics_path,
        extra_params: request.query_parameters.except(:interval)
      )

      # Display settings button — pushed to the far right on wide
      # viewports; wraps naturally on narrow ones. Only shown when
      # there's an active scope (no island → no data → no charts to
      # configure).
      if @data
        div(class: "ml-auto") do
          render Components::Metrics::DisplaySettingsButton.new(
            kind:                @data.display_kind,
            scope_kind:          @data.scope_kind,
            display_settings_url: metrics_display_settings_path
          )
        end
      end
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
  # Update strategy: ActionCable broadcast over Solid Cable. The
  # MetricsSyncIslandJob fires `metrics_tick` after inserting new
  # samples, every page subscribed to `metrics-#{island.id}`
  # reloads its per-card frames in place (see
  # turbo_actions/metrics.js). Polling tick was removed: with
  # lazy-loaded sub-frames, reloading the parent caused skeleton
  # flicker every 30s — broadcast covers the same job cadence
  # without the visual cost.
  #
  # Trade-off documented: if Solid Cable / WebSocket connection
  # drops (rare in local dev, possible on mobile/network change),
  # data freezes until next manual refresh. Acceptable for a
  # local self-hosted dashboard; if a SaaS surface ever wants
  # multi-second polling fallback, a follow-up can re-introduce
  # polling behind an opt-in URL toggle (e.g. ?auto_refresh=poll).
  def chart_grid
    return if @data.nil?

    # Single turbo-frame carrying ALL chart cards inline. The
    # metrics_tick broadcast (see turbo_actions/metrics.js) calls
    # frame.reload() which refetches `src` — server detects the
    # Turbo-Frame header in MetricsController#index and returns
    # Views::Metrics::Frame with fresh data, Turbo atomically
    # swaps the contents. No per-card subframes, no skeleton flash.
    # metrics-display controller wraps the chart content INSIDE the
    # frame so it reconnects automatically on every broadcast-tick
    # swap and re-applies the operator's hidden-metrics filter +
    # custom card ordering. kindValue drives sessionStorage namespace
    # (deployment vs host vs statefulset — independent display
    # configs per workload kind).
    #
    # Resource + HTTP cards now share ONE grid (no divider). Each
    # HTTP card gets an inline [http] badge inside the card header
    # so the visual cue stays without breaking the grid into two
    # boxes — and operators can interleave resource/HTTP charts in
    # their preferred order via the Settings drawer.
    turbo_frame_tag("metrics-charts", src: current_request_url) do
      div(
        class: "flex flex-col gap-4 vmd:gap-5",
        data: {
          controller:                "metrics-display",
          metrics_display_kind_value: @data.display_kind
        }
      ) do
        all_charts = @data.charts + (@data.ingress_eligible? ? @data.http_charts : [])
        render_chart_cards(all_charts)
      end
    end
  end

  # render_chart_cards — renders ChartCards with data fetched
  # server-side (no lazy sub-frames). The parent metrics-charts
  # turbo-frame handles refresh as a single atomic swap on
  # broadcast tick — see turbo_actions/metrics.js.
  # render_chart_cards — grid wrapper carries data-metrics-display-target="grid"
  # so the metrics-display controller can mutate gridTemplateColumns
  # at runtime. Server defaults to 2-col at vmd+ via Tailwind class;
  # JS overrides based on visible count + operator's saved cols pref.
  def render_chart_cards(charts)
    div(
      class: "grid grid-cols-1 vmd:grid-cols-2 gap-3",
      data:  { metrics_display_target: "grid" }
    ) do
      charts.each do |c|
        render Components::Metrics::ChartCard.new(
          label:           c[:label],
          color:           c[:color],
          unit:            c[:unit],
          points:          c[:points],
          range_ms:        @data.range_ms,
          current:         c[:current],
          expand_url:      expand_url_for(c),
          metric:          c[:metric],
          section:         c[:section],
          default_visible: c.fetch(:default_visible, true),
          capacity_label:  c[:capacity_label],
          capacity_pct:    c[:capacity_pct]
        )
      end
    end
  end

  # expand_url_for — URL the maximize button anchors to (turbo_stream
  # response → opens shared modal). Echoes parent page scope/range
  # so the modal starts at the same view, layers on metric metadata
  # so the endpoint rebuilds the right single-chart slice.
  def expand_url_for(chart)
    qp = {
      scope_kind: @data&.scope_kind || "host",
      scope_id:   @data&.scope_id,
      range:      @data&.range || "1h",
      # `auto` is the default — omit from the URL so default views
      # have a clean `?range=1h` instead of `?range=1h&interval=auto`.
      interval:   (@data&.interval && @data.interval != "auto") ? @data.interval : nil,
      metric:     chart[:metric],
      scale:      chart[:scale],
      label:      chart[:label],
      color:      chart[:color],
      unit:       chart[:unit]
    }.compact

    "#{metrics_chart_path}?#{qp.to_query}"
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
