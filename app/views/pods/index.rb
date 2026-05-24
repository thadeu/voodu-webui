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
      current_island: @current_island, updated_at: @updated_at
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
