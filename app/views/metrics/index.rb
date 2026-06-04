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
        controller: "auto-refresh fullscreen",
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
    )
  end

  # dashboard_mode? — true when @data is a MetricDashboardData (a saved
  # dashboard is being rendered) vs a scope (host/pod) view.
  def dashboard_mode?
    @data.respond_to?(:dashboard?) && @data.dashboard?
  end

  # dashboard_switcher_group — one control that (a) shows the CURRENT
  # view's name (the active dashboard, or "Host (default)") so it's
  # obvious which view you're on, (b) opens the switcher/manager drawer
  # on click, and (c) carries an attached Pin toggle when a dashboard is
  # active. Present in both modes.
  # dashboard_switcher_group — a dropdown (switch dashboards inline,
  # without opening the drawer every time) + the attached pin. The
  # dropdown lists Host + every dashboard; its top row "Manage
  # dashboards" opens the right drawer for new/edit/delete.
  def dashboard_switcher_group
    div(class: "inline-flex items-stretch") do
      # The Drawer WRAPS the dropdown (custom_trigger) so the "Manage"
      # row inside the menu sits in the drawer's Stimulus scope, while
      # the drawer PANEL renders as a sibling of the menu — not hidden
      # or clipped to 0-width when the dropdown menu toggles.
      render(Components::UI::Drawer.new(
        title:               "Dashboards",
        src:                 "#{metric_dashboards_path}?embed=1",
        open_url:            metric_dashboards_path,
        width:               "30vw",
        min_width:           "300px",
        max_width:           "min(100vw, 560px)",
        show_full_page_link: false,
        permanent:           false,
        custom_trigger:      true,
        storage_key:         "voodu:drawer-width:dashboards"
      )) do
        div(
          class: "relative",
          data: {
            controller:                     "dropdown metric-multiselect",
            metric_multiselect_base_value:     metrics_path,
            metric_multiselect_selected_value: current_pids.join(",")
          }
        ) do
          button(
            type: "button",
            data: { action: "click->dropdown#toggle" },
            class: switcher_trigger_classes
          ) do
            render Icon::Squares2x2Outline.new(class: "w-3.5 h-3.5 shrink-0")
            span(class: "truncate max-w-[180px]") { current_view_name }
            render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 text-voodu-muted shrink-0")
          end

          div(
            hidden: true,
            data:  { dropdown_target: "menu" },
            class: "absolute left-0 top-[calc(100%+4px)] z-50 min-w-[260px] max-h-[420px] " \
                   "overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface-2 shadow-2xl"
          ) do
            # Manage row — opens the wrapping drawer + closes the dropdown.
            button(
              type: "button",
              data: { action: "click->drawer#open click->dropdown#close" },
              class: "flex items-center gap-2.5 w-full px-3 py-2 min-h-[36px] text-left " \
                     "text-[12px] font-medium text-voodu-text-2 hover:bg-voodu-hover"
            ) do
              render Icon::Squares2x2Outline.new(class: "w-3.5 h-3.5 shrink-0")
              span(class: "flex-1") { "Manage dashboards" }
              render Icon::ArrowRightOutline.new(class: "w-3 h-3 text-voodu-muted-2 shrink-0")
            end

            div(class: "h-px bg-voodu-border")

            # Host row — exclusive: navigates immediately and clears any
            # dashboard selection (host is a single scope, not stackable).
            switch_menu_item(
              label:  "Host (default)",
              href:   metrics_path(scope_kind: "host"),
              active: !dashboard_mode?,
              icon:   :ChartBarOutline
            )

            # Dashboard rows — checkbox toggles (no nav per click). Pick
            # several, then "View selected" stacks them in pick order.
            all_dashboards.each do |d|
              multiselect_row(d, selected: current_pids.include?(d.uuid))
            end

            if all_dashboards.any?
              div(class: "h-px bg-voodu-border")

              button(
                type: "button",
                data: { action: "click->metric-multiselect#apply", metric_multiselect_target: "apply" },
                class: "flex items-center justify-center gap-1.5 w-full px-3 py-2 min-h-[38px] " \
                       "text-[12px] font-semibold text-voodu-accent-2 hover:bg-voodu-accent-dim"
              ) do
                render Icon::ArrowRightOutline.new(class: "w-3 h-3 shrink-0")
                span(data: { metric_multiselect_target: "summary" }) { "View selected" }
              end
            end
          end
        end
      end

      pin_segment
    end
  end

  # all_dashboards — the island's saved dashboards (for the switcher
  # dropdown list).
  def all_dashboards
    @all_dashboards ||= @current_island ? @current_island.metric_dashboards.order(:name).to_a : []
  end

  # switch_menu_item — a dropdown row that navigates to a view. Plain
  # full-page nav (toolbar isn't in a turbo_frame); the active row is
  # highlighted + checked.
  def switch_menu_item(label:, href:, active:, icon:, accent: false)
    a(
      href: href,
      data: { turbo: false },
      class: tokens(
        "flex items-center gap-2.5 w-full px-3 py-2 min-h-[36px] text-left text-[12.5px]",
        active ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text hover:bg-voodu-hover"
      )
    ) do
      render Icon.const_get(icon).new(class: tokens("w-3.5 h-3.5 shrink-0", accent ? "text-voodu-accent-2" : nil))
      span(class: "flex-1 truncate") { label }
      render Icon::CheckOutline.new(class: "w-3 h-3 text-voodu-accent-2 shrink-0") if active
    end
  end

  # current_pids — the uuids currently in ?pid=, in order. Drives which
  # rows start checked + the JS initial selection order.
  def current_pids
    @current_pids ||= request.query_parameters[:pid].to_s.split(",").map(&:strip).reject(&:blank?)
  end

  # multiselect_row — a checkbox dashboard row. Toggled client-side by
  # metric_multiselect_controller (no nav); the shared "View selected"
  # button navigates to the stacked view in selection order.
  def multiselect_row(dash, selected:)
    button(
      type: "button",
      data: {
        action:                  "click->metric-multiselect#toggle",
        metric_multiselect_target: "row",
        uuid:                    dash.uuid,
        checked:                 selected.to_s
      },
      class: "flex items-center gap-2.5 w-full px-3 py-2 min-h-[36px] text-left " \
             "text-[12.5px] text-voodu-text hover:bg-voodu-hover"
    ) do
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

      render(
        dash.pinned ?
          Icon::BookmarkSolid.new(class: "w-3.5 h-3.5 text-voodu-accent-2 shrink-0") :
          Icon::Squares2x2Outline.new(class: "w-3.5 h-3.5 text-voodu-muted shrink-0")
      )
      span(class: "flex-1 truncate") { dash.name }
    end
  end

  # current_view_name — label for the switcher trigger.
  def current_view_name
    if multi_mode?
      n = @data.dashboards.size

      return "#{n} dashboards"
    end

    return @data.dashboard&.name.presence || "Dashboard" if dashboard_mode?

    "Host (default)"
  end

  # The pin always renders, so the trigger always drops its right
  # border → one shared divider, the two read as one grouped control.
  def switcher_trigger_classes
    "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border border-r-0 bg-voodu-surface " \
      "text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
  end

  # pinned_dashboard — the island's single pinned dashboard (the
  # default /metrics opens to), or nil when host is the default.
  def pinned_dashboard
    return @pinned_dashboard if defined?(@pinned_dashboard)

    @pinned_dashboard = @current_island&.metric_dashboards&.pinned&.first
  end

  # pin_segment — right half of the switcher group. ALWAYS shown, as a
  # toggle for "is THIS view the default /metrics opens to":
  #   - dashboard mode → pin/unpin THIS dashboard (filled when pinned)
  #   - host mode      → host-as-default. Filled when nothing is pinned
  #     (host IS the default); when a dashboard is pinned it's an
  #     outline button that unpins it (→ host becomes the default).
  # Native POST (toolbar lives outside any turbo_frame).
  def pin_segment
    if dashboard_mode? && !multi_mode?
      dash = @data.dashboard
      return pin_indicator(active: false, title: "No dashboard") if dash.nil?

      if dash.pinned
        pin_form(action: unpin_metric_dashboard_path(dash), active: true,
                 title: "Unpin — /metrics stops opening to this dashboard")
      else
        pin_form(action: pin_metric_dashboard_path(dash), active: false,
                 title: "Pin — open /metrics to this dashboard")
      end
    elsif (pinned = pinned_dashboard)
      # On host while a dashboard is pinned: clicking makes host the
      # default again (unpins it).
      pin_form(action: unpin_metric_dashboard_path(pinned), active: false,
               title: "Make host the default — unpins #{pinned.name}")
    else
      # Host is already the default (nothing pinned).
      pin_indicator(active: true, title: "Host is the default /metrics view")
    end
  end

  def pin_form(action:, active:, title:)
    form(action: action, method: "post", data: { turbo: false }, class: "inline-flex") do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      button(type: "submit", title: title, "aria-label": title, class: pin_btn_classes(active)) do
        pin_icon(active)
      end
    end
  end

  # pin_indicator — non-submitting state (current view is already the
  # default; nothing to toggle).
  def pin_indicator(active:, title:)
    span(title: title, class: "#{pin_btn_classes(active)} cursor-default") { pin_icon(active) }
  end

  def pin_icon(active)
    render(active ? Icon::BookmarkSolid.new(class: "w-3.5 h-3.5") : Icon::BookmarkOutline.new(class: "w-3.5 h-3.5"))
  end

  def pin_btn_classes(active)
    tokens(
      "inline-flex items-center justify-center w-9 h-9 border",
      active ? "border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2"
             : "border-voodu-border bg-voodu-surface text-voodu-muted hover:bg-voodu-surface-2 hover:text-voodu-text"
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
    if multi_mode?
      span do
        plain "dashboards "
        span(class: "font-voodu-mono text-voodu-text-2") { @data.dashboards.map(&:name).join(" + ") }
      end
    elsif dashboard_mode?
      dash = @data.dashboard
      span do
        plain "dashboard "
        span(class: "font-voodu-mono text-voodu-text-2") { dash&.name }
        if dash
          plain " · "
          plain "#{dash.panels_count} #{dash.panels_count == 1 ? 'panel' : 'panels'}"
        end
      end
    elsif @data&.scope_kind == "pod" && (pod = @data.pod_record)
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
    @data.respond_to?(:scope_kind) && @data.scope_kind == "pod" && @data.scope_id.present?
  end

  # refresh_btn removed — the metrics-charts turbo-frame polls
  # via metrics-tick broadcasts + the auto-refresh toggle in the
  # toolbar already keeps charts live. A manual Refresh button is
  # redundant chrome that crowds the actions row; the polling tick
  # is the source of truth for "fresh data on screen".

  def toolbar
    div(class: "flex items-center gap-2.5 flex-wrap") do
      render Components::Metrics::RangePicker.new(range: @data&.range || "1h")
      render Components::Metrics::IntervalPicker.new(
        current:      @data&.interval || "auto",
        base_path:    metrics_path,
        extra_params: request.query_parameters.except(:interval)
      )

      # Right cluster, pushed far right (ml-auto), wraps on narrow
      # viewports. Order: [view-name + pin group] · [pod picker] · Order.
      # The pod picker sits right of the switcher group (scope mode only —
      # dashboard mode shares one range/interval across its panels).
      div(class: "ml-auto flex items-center gap-2 flex-wrap") do
        dashboard_switcher_group

        unless dashboard_mode?
          render Components::Metrics::PodPicker.new(
            scope_kind:     @data&.scope_kind || "host",
            scope_id:       @data&.scope_id,
            current_island: @current_island,
            pods:           @data&.all_pods || []
          )
        end

        # Multi mode shows no shared Settings/Order — each stacked section
        # keeps its own saved hide/reorder layout (display_kind per
        # dashboard), edited from its single-dashboard view.
        if multi_mode?
          nil
        elsif dashboard_mode?
          render Components::Metrics::DisplaySettingsButton.new(
            kind:                 @data.display_kind,
            scope_kind:           "host",
            display_settings_url: metrics_display_settings_path,
            dashboard_id:         @data.dashboard&.uuid
          )
        elsif @data
          render Components::Metrics::DisplaySettingsButton.new(
            kind:                @data.display_kind,
            scope_kind:          @data.scope_kind,
            display_settings_url: metrics_display_settings_path
          )
        end

        fullscreen_button if @data
      end
    end
  end

  # fullscreen_button — blows the live chart grid up to a 97vw × 97vh
  # overlay (fullscreen_controller). Handy for a multi-dashboard stack:
  # see every selected panel at once. Esc / backdrop / ✕ exit.
  def fullscreen_button
    button(
      type:  "button",
      data:  { action: "click->fullscreen#open" },
      title: "Fullscreen",
      "aria-label": "View charts fullscreen",
      class: "inline-flex items-center justify-center w-9 h-9 border border-voodu-border bg-voodu-surface " \
             "text-voodu-muted hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) do
      render Icon::ArrowsPointingOutOutline.new(class: "w-3.5 h-3.5")
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
    # Backdrop — sibling of the panel, dim layer behind the fullscreen
    # overlay. Hidden until fullscreen_controller#open; clicking it exits.
    div(
      hidden: true,
      data:  { fullscreen_target: "backdrop", action: "click->fullscreen#close" },
      class: "fixed inset-0 z-[60] bg-black/70 backdrop-blur-sm"
    )

    # Panel — the LIVE grid. fullscreen_controller toggles fixed 97vw/97vh
    # classes ON this element, so the turbo-frame inside keeps swapping on
    # the realtime tick (no clone). The chrome bar + frame are children
    # the frame swap never touches (chrome is a sibling of the frame).
    div(data: { fullscreen_target: "panel" }, class: "min-w-0") do
      fullscreen_chrome
      div(data: { fullscreen_target: "body" }) do
        turbo_frame_tag("metrics-charts", src: current_request_url) do
          if multi_mode?
            div(class: "flex flex-col gap-5 vmd:gap-6") do
              @data.sections.each { |sec| dashboard_section(sec) }
            end
          else
            grid_for(@data)
          end
        end
      end
    end
  end

  # fullscreen_chrome — slim sticky bar shown only in fullscreen: the
  # view name on the left, the close (✕) pinned top-right. Sticky so it
  # stays reachable while the operator scrolls the stacked panels.
  # Sibling of the turbo-frame → realtime swaps never remove it.
  def fullscreen_chrome
    div(
      hidden: true,
      data:  { fullscreen_target: "chrome" },
      class: "sticky top-0 z-10 flex items-center justify-between gap-3 h-10 px-3 " \
             "bg-voodu-surface-2/95 backdrop-blur-sm border-b border-voodu-border-2"
    ) do
      div(class: "flex items-center gap-2 min-w-0") do
        render Icon::Squares2x2Outline.new(class: "w-3.5 h-3.5 text-voodu-muted shrink-0")
        span(class: "text-[12px] font-medium text-voodu-text-2 truncate") { fullscreen_title }
      end

      button(
        type:  "button",
        data:  { action: "click->fullscreen#close" },
        title: "Exit fullscreen (Esc)",
        "aria-label": "Exit fullscreen",
        class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface shrink-0"
      ) do
        render Icon::XMarkOutline.new(class: "w-4 h-4")
      end
    end
  end

  # fullscreen_title — what the chrome bar labels the overlay with:
  # the joined dashboard names (multi), the single dashboard, or the
  # scope (host/pod).
  def fullscreen_title
    if multi_mode?
      @data.dashboards.map(&:name).join("  +  ")
    elsif dashboard_mode?
      @data.dashboard&.name.to_s
    elsif @data.respond_to?(:scope_kind) && @data.scope_kind == "pod"
      @data.scope_id.to_s
    else
      "Host"
    end
  end

  # multi_mode? — true when several dashboards are stacked (?pid=a,b).
  def multi_mode?
    @data.respond_to?(:multi?) && @data.multi?
  end

  # dashboard_section — one stacked dashboard in a multi-view: a name
  # header + its own metrics-display grid (independent saved layout).
  def dashboard_section(sec)
    dash = sec.dashboard

    div(class: "flex flex-col gap-3") do
      div(class: "flex items-baseline gap-2.5") do
        render Icon::Squares2x2Outline.new(class: "w-3.5 h-3.5 text-voodu-muted shrink-0 self-center")
        span(class: "text-[13px] font-semibold text-voodu-text") { dash&.name }
        span(class: "text-[11.5px] text-voodu-muted") do
          plain "#{dash&.panels_count} #{dash&.panels_count == 1 ? 'panel' : 'panels'}"
        end
        span(class: "flex-1 h-px bg-voodu-border-2 self-center ml-1")
      end

      grid_for(sec)
    end
  end

  # grid_for — the metrics-display-wrapped chart grid for ONE data
  # object (a single dashboard/scope, or one section of a multi-view).
  # Each carries its own display_kind so saved hide/reorder is scoped.
  def grid_for(data)
    div(
      class: "flex flex-col gap-4 vmd:gap-5",
      data: {
        controller:                 "metrics-display",
        metrics_display_kind_value: data.display_kind
      }
    ) do
      all_charts = data.charts + (data.ingress_eligible? ? data.http_charts : [])
      render_chart_cards(all_charts, data)
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
  def render_chart_cards(charts, data)
    div(
      class: "grid grid-cols-1 vmd:grid-cols-2 gap-3",
      data:  { metrics_display_target: "grid" }
    ) do
      charts.each do |c|
        if c[:missing]
          render_missing_card(c)
        else
          render Components::Metrics::ChartCard.new(
            label:           c[:label],
            color:           c[:color],
            unit:            c[:unit],
            points:          c[:points],
            range_ms:        data.range_ms,
            current:         c[:current],
            expand_url:      expand_url_for(c, data),
            # data-metric-key the Settings/Order drawer matches on. In
            # dashboard mode it's the unique panel_key (charts can share
            # a metric); in scope mode there's one card per metric so the
            # metric name itself is unique.
            metric:          c[:panel_key] || c[:metric],
            section:         c[:section],
            default_visible: c.fetch(:default_visible, true),
            capacity_label:  c[:capacity_label],
            capacity_pct:    c[:capacity_pct]
          )
        end
      end
    end
  end

  # render_missing_card — placeholder tile for a dashboard panel whose
  # workload has no running replica right now (scaled to zero, deleted,
  # mid-redeploy). Dashed border so it reads as "intentionally empty,
  # not broken"; the panel returns the moment a replica comes back.
  def render_missing_card(c)
    div(
      class: "bg-voodu-surface border border-voodu-border border-dashed p-3.5 flex flex-col gap-2 min-w-0",
      data:  c[:panel_key] ? { metrics_display_target: "card", metric_key: c[:panel_key] } : {}
    ) do
      span(
        class: "text-[11.5px] font-semibold uppercase tracking-[0.05em]",
        style: "color: #{c[:color]};"
      ) { c[:label] }

      div(class: "flex items-center justify-center w-full h-[120px] text-[12px] text-voodu-muted text-center px-3") do
        plain "no running replica for #{c[:source_label]}"
      end
    end
  end

  # expand_url_for — URL the maximize button anchors to (turbo_stream
  # response → opens shared modal). Echoes parent page scope/range
  # so the modal starts at the same view, layers on metric metadata
  # so the endpoint rebuilds the right single-chart slice.
  def expand_url_for(chart, data)
    # Dashboard charts carry their own resolved scope_kind/scope_id
    # (each panel resolves to its own pod); scope-mode charts inherit
    # the page's single scope.
    sk  = chart[:scope_kind] || (data.respond_to?(:scope_kind) ? data.scope_kind : nil)
    sid = chart[:scope_id]   || (data.respond_to?(:scope_id)   ? data.scope_id   : nil)

    qp = {
      scope_kind: sk || "host",
      scope_id:   sid,
      range:      data&.range || "1h",
      # `auto` is the default — omit from the URL so default views
      # have a clean `?range=1h` instead of `?range=1h&interval=auto`.
      interval:   (data&.interval && data.interval != "auto") ? data.interval : nil,
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
