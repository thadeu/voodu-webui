# frozen_string_literal: true

# Views::Dashboard::Index — Overview screen.
#
# Three-state pattern:
#   - no island       → NoIslandState
#   - controller err  → ErrorState banner inline above the (mocked) body
#   - happy           → header + stat cards (auto-fit grid) + pods section
class Views::Dashboard::Index < Views::Base
  def initialize(current_path:, islands: [], current_island: nil, data: nil, active_tab: :all, updated_at: nil)
    @current_path = current_path
    @islands = islands
    @current_island = current_island
    @data = data
    @active_tab = active_tab
    @updated_at = updated_at
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path,
      islands: @islands,
      current_island: @current_island,
      updated_at: @updated_at,
      uptime: @data&.uptime_label,
      breadcrumb: overview_crumbs
    ) do
      if @current_island.nil?
        render Components::UI::NoIslandState.new
      else
        overview_body
      end
    end
  end

  private

  # overview_body — wrapped in a Turbo Frame so StateSyncIslandJob's
  # state_tick broadcast can refresh it without a page reload. We
  # DON'T set src= on the frame (would cause Turbo to auto-fetch on
  # connect, which can blank out the body before the network round-
  # trip completes). Instead, the state-tick JS handler sets
  # frame.src = window.location.href just before calling reload().
  # Same effect, no first-paint flash.
  #
  # `data-state-frame` is the opt-in marker the JS action looks
  # for — sibling pages (Logs, Settings) that don't want this
  # behaviour simply don't set it.
  def overview_body
    # `target="_top"` is critical here: without it Turbo would treat
    # any link inside this frame (every pod row, every action button)
    # as a frame-navigation — clicking a pod would request /pods/:name
    # with a Turbo-Frame header, the response wouldn't have a matching
    # frame, and Turbo would render "Content missing". `_top` flips the
    # default so links navigate the whole page; the frame remains
    # programmatically reload()-able by state_tick.
    # `refresh="morph"` — see Views::Pods::Show#framed_body for the
    # full rationale. Short version: Turbo 8 morph rendering respects
    # `[data-turbo-permanent]` and updates only the nodes that changed,
    # so open drawers / modals keep their client state across the
    # state_tick reload.
    turbo_frame_tag(
      "island-#{@current_island.id}-state",
      target: "_top",
      refresh: "morph",
      data: {state_frame: true}
    ) do
      div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
        stale_banner if @data&.stale?
        error_banner if @data&.error
        page_header
        stat_cards
        pods_section
      end
    end
  end

  # stale_banner — rendered when the controller is unreachable but
  # we have a local snapshot (WAREHOUSE=1). Tells the operator
  # "you're looking at saved data, not real-time" so the running
  # counts + chart values aren't misread as live. Different copy
  # from error_banner because there's nothing to fix — just wait
  # for the agent to come back.
  def stale_banner
    age = @data.updated_at ? "#{time_ago_in_words(@data.updated_at)} ago" : "moments ago"

    div(
      class: "px-3 py-2 border border-voodu-amber/40 bg-voodu-amber-dim text-voodu-amber text-[12.5px] flex items-center gap-2"
    ) do
      render Icon::ExclamationTriangleOutline.new(class: "w-3.5 h-3.5")
      span { "Controller offline — showing last-known state from " }
      span(class: "font-voodu-mono opacity-80") { age }
      span { ". Pod statuses are uncertain until the agent comes back." }
    end
  end

  def error_banner
    div(
      class: "px-3 py-2 border border-voodu-red/40 bg-voodu-red-dim text-voodu-red text-[12.5px] flex items-center gap-2"
    ) do
      render Icon::ExclamationTriangleOutline.new(class: "w-3.5 h-3.5")
      span { "Couldn't reach the server — showing mocked values. " }
      span(class: "font-voodu-mono opacity-80") { @data.error.message }
    end
  end

  # page_header — flex-wrap means the action buttons stay inline on
  # wide viewports and naturally fall to a new line when there
  # isn't room. Matches the inspiration's `pageHead` style.
  #
  # "Refresh all" was removed — the topbar "updated Ns ago" chip is
  # the refresh affordance now (click bypasses the cache). Operators
  # were misreading the prominent purple button as "restart all
  # pods" which it never was; folding the action into the chip
  # makes the cause-and-effect obvious ("update" → "click to update
  # again").
  def page_header
    div(class: "flex flex-wrap items-end justify-between gap-3 vmd:gap-4") do
      div(class: "min-w-0") do
        h1(class: "text-[22px] font-semibold text-voodu-text tracking-tight") { "Overview" }
        page_sub
      end
      div(class: "flex items-center gap-2 shrink-0") do
        open_logs_btn
      end
    end
  end

  # page_sub — "name · 11 of 14 pods running · load avg X / X / X".
  # The load-avg segment is hidden below vd-md (matches inspiration:
  # `{!isMobile && (...)}`).
  def page_sub
    div(class: "flex flex-wrap items-center gap-2.5 mt-1 text-[12.5px] text-voodu-muted") do
      span(class: "font-voodu-mono") { @current_island.name }
      dot_sep
      span { "#{@data.pods_running_count} of #{@data.pods_total} pods running" }

      # Load avg only on 1100+ — mobile drops it to keep one line.
      span(class: "hidden vmd:contents") do
        dot_sep
        span do
          plain "load avg "
          span(class: "font-voodu-mono text-voodu-text-2") { "#{@data.load_1} / #{@data.load_5} / #{@data.load_15}" }
        end
      end
    end
  end

  def dot_sep
    span(
      class: "inline-block w-[3px] h-[3px] rounded-full bg-voodu-border-2",
      aria: {hidden: "true"}
    )
  end

  def open_logs_btn
    a(
      href: logs_analytics_path,
      class: "inline-flex items-center gap-1.5 px-3 h-9 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12.5px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text"
    ) do
      render Icon::DocumentTextOutline.new(class: "w-3.5 h-3.5")
      span { "Open logs" }
    end
  end

  # stat_cards — auto-fit grid (the inspiration's `metricsGrid`
  # pattern). The browser packs as many cards as fit in 190px
  # minimum tracks, then equalises. No breakpoint juggling needed:
  # 1 col on narrow phones, 2 in mid mobile, 3-4 on tablet, 4 on
  # desktop.
  def stat_cards
    div(
      class: "grid gap-3",
      style: "grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));"
    ) do
      @data.stat_cards.each do |card|
        render Components::Overview::StatCard.new(**card)
      end
    end
  end

  def pods_section
    render Components::Overview::PodsTable.new(
      pods: @data.pods(filter_status: tab_to_status),
      total: @data.pods_total,
      active_tab: @active_tab
    )
  end

  def tab_to_status
    return nil if @active_tab == :all

    @active_tab
  end
end
