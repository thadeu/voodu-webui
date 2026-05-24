# frozen_string_literal: true

# Views::Dashboard::Index — Overview screen.
#
# Three-state pattern:
#   - no island       → NoIslandState
#   - controller err  → ErrorState banner inline above the (mocked) body
#   - happy           → header + stat cards (auto-fit grid) + pods section
class Views::Dashboard::Index < Views::Base
  def initialize(current_path:, islands: [], current_island: nil, data: nil, active_tab: :all, updated_at: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @data           = data
    @active_tab     = active_tab
    @updated_at     = updated_at
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path,
      islands: @islands,
      current_island: @current_island,
      updated_at: @updated_at,
      uptime: @data&.uptime_label
    ) do
      if @current_island.nil?
        render Components::UI::NoIslandState.new
      else
        overview_body
      end
    end
  end

  private

  def overview_body
    div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
      error_banner if @data&.error
      page_header
      stat_cards
      pods_section
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
      aria: { hidden: "true" }
    )
  end

  def open_logs_btn
    a(
      href: "/logs",
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
