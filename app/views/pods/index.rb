# frozen_string_literal: true

# Views::Pods::Index — full pod list page.
#
# Header carries the status breakdown (X running · Y restarting · Z
# stopped) plus the list of distinct scopes detected. Body reuses
# Components::Overview::PodsTable (same widget the dashboard uses)
# so the table look stays consistent between Overview and the
# dedicated /pods page.
class Views::Pods::Index < Views::Base
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
      current_path: @current_path, islands: @islands,
      current_island: @current_island, updated_at: @updated_at,
      breadcrumb: overview_crumbs({ label: "Pods" })
    ) do
      if @current_island.nil?
        render Components::UI::NoIslandState.new
      else
        body
      end
    end
  end

  private

  # body — wrapped in a Turbo Frame so StateSyncIslandJob's
  # state_tick broadcast can refresh it without a page reload. No
  # src= on the frame (would cause Turbo to auto-fetch on connect
  # and possibly blank the body). The state-tick JS handler sets
  # frame.src = window.location.href right before reload() — same
  # effect, no first-paint flash, preserves active_tab filter
  # because window.location carries the query string.
  def body
    # `target="_top"` — links inside the frame (every pod row, the
    # tab pills that filter by status, etc.) navigate the whole
    # page instead of getting trapped by Turbo's frame navigation.
    # Without it, clicking a pod row would render "Content missing"
    # because the /pods/:name response has no matching frame.
    # See Views::Dashboard::Index for the same fix.
    # `refresh="morph"` — see Views::Pods::Show#framed_body for the
    # full rationale. Short version: Turbo 8 morph rendering respects
    # `[data-turbo-permanent]` and updates only the nodes that changed,
    # so open drawers / modals keep their client state across the
    # state_tick reload.
    turbo_frame_tag(
      "island-#{@current_island.id}-state",
      target:  "_top",
      refresh: "morph",
      data:    { state_frame: true }
    ) do
      div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
        stale_banner if @data&.stale?
        error_banner if @data&.error
        page_header
        # show_heading: false — the page_header above already renders
        # the H1 "Pods" + status counts. Letting PodsTable draw its
        # own H2 "Pods" right under it stacks two identical labels
        # (the Overview screen doesn't have this problem because its
        # H1 is "Overview").
        render Components::Overview::PodsTable.new(
          pods: @data.pods(filter_status: tab_to_status),
          total: @data.pods_total,
          active_tab: @active_tab,
          show_heading: false
        )
      end
    end
  end

  # stale_banner — mirrors the Overview's stale banner. Surfaces the
  # "controller offline · showing last-known state" message at the
  # top of /pods too so the operator gets the same signal regardless
  # of which page they land on.
  def stale_banner
    age = @data.updated_at ? "#{time_ago_in_words(@data.updated_at)} ago" : "moments ago"

    div(class: "px-3 py-2 border border-voodu-amber/40 bg-voodu-amber-dim text-voodu-amber text-[12.5px] flex items-center gap-2") do
      render Icon::ExclamationTriangleOutline.new(class: "w-3.5 h-3.5")
      span { "Controller offline — showing last-known state from " }
      span(class: "font-voodu-mono opacity-80") { age }
      span { ". Pod statuses are uncertain until the agent comes back." }
    end
  end

  def error_banner
    div(class: "px-3 py-2 border border-voodu-red/40 bg-voodu-red-dim text-voodu-red text-[12.5px] flex items-center gap-2") do
      render Icon::ExclamationTriangleOutline.new(class: "w-3.5 h-3.5")
      span { "Couldn't reach the server — showing mocked values. " }
      span(class: "font-voodu-mono opacity-80") { @data.error.message }
    end
  end

  # page_header — H1 + status counts subline.
  #
  # The Refresh button was removed alongside the Overview's
  # "Refresh all" — the topbar "updated Ns ago" chip is now the
  # single refresh affordance across every page. Click bypasses
  # the page's snapshot cache.
  def page_header
    div(class: "flex flex-wrap items-end justify-between gap-3 vmd:gap-4") do
      div(class: "min-w-0") do
        h1(class: "text-[22px] font-semibold text-voodu-text tracking-tight") { "Pods" }
        page_sub
      end
    end
  end

  # page_sub — "● 11 running · ● 1 restarting · ● 2 stopped · 5
  # scopes: clowk-vd, data, monitoring, edge, backup". Scopes line is
  # hidden below vd-md to keep mobile single-line.
  def page_sub
    counts = status_counts
    scopes = @data.scopes

    div(class: "flex flex-wrap items-center gap-2.5 mt-1 text-[12.5px] text-voodu-muted") do
      stat_bit("var(--voodu-green)", "running",    counts[:running])
      dot_sep
      stat_bit("var(--voodu-amber)", "restarting", counts[:restarting])
      dot_sep
      stat_bit("var(--voodu-muted)", "stopped",    counts[:stopped])

      next if scopes.empty?

      span(class: "hidden vmd:contents") do
        dot_sep
        span do
          plain "#{scopes.size} scope#{'s' unless scopes.size == 1}: "
          span(class: "font-voodu-mono text-voodu-text-2") { scopes.join(", ") }
        end
      end
    end
  end

  def stat_bit(color, label, count)
    span(class: "inline-flex items-center gap-1.5") do
      span(class: "inline-block w-1.5 h-1.5 rounded-full", style: "background: #{color};")
      span(class: "font-voodu-mono text-voodu-text-2") { count.to_s }
      span { label }
    end
  end

  def dot_sep
    span(
      class: "inline-block w-[3px] h-[3px] rounded-full bg-voodu-border-2",
      aria: { hidden: "true" }
    )
  end

  def status_counts
    all = @data.pods(filter_status: nil)
    {
      running:    all.count { |p| p[:status] == :running },
      restarting: all.count { |p| p[:status] == :restarting },
      stopped:    all.count { |p| p[:status] == :stopped }
    }
  end

  def tab_to_status
    return nil if @active_tab == :all

    @active_tab
  end
end
