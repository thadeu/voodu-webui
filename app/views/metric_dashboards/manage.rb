# frozen_string_literal: true

# Views::MetricDashboards::Manage — the dashboard manager. A full-page
# Components::UI::Modal (:xl) over the dashboard chrome, laid out master-detail:
# a vertical rail of saved dashboards on the left, the selected dashboard's
# editor in a turbo-frame on the right. Replaces the old right-drawer (which
# made you bounce list → edit → back-arrow → list).
#
# Selecting a rail item (or "New") swaps the EDITOR_FRAME to that editor; Save
# redirects to /metrics (closing the modal). The in-builder drag-sort +
# per-panel edit live inside the editor (Views::MetricDashboards::Form).
class Views::MetricDashboards::Manage < Views::Base
  EDITOR_FRAME = "dashboard-editor"

  def initialize(island:, dashboards:, current_path:, islands: [], current_island: nil, active_uuid: nil)
    @island = island
    @dashboards = dashboards
    @current_path = current_path
    @islands = islands
    @current_island = current_island
    @active_uuid = active_uuid
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, islands: @islands, current_island: @current_island,
      breadcrumb: overview_crumbs({label: "Metrics"})
    ) do
      render(modal) { body }
    end
  end

  private

  def modal
    Components::UI::Modal.new(
      title: "Dashboards",
      subtitle: "Build and organise your metric dashboards",
      icon: :Squares2x2Outline,
      size: :xl,
      close_to: metrics_path
    )
  end

  # body — master-detail: rail + editor frame. Column on mobile (rail strip on
  # top), row at vmd+. A usable min-height on mobile; a tall fixed height at vmd+
  # (matching the call-flow modal's 82vh) so the editor scrolls inside the modal
  # rather than growing it, and the panel list gets real vertical room.
  def body
    div(class: "flex flex-col vmd:flex-row min-h-[440px] vmd:min-h-0 vmd:h-[82vh] vmd:max-h-[calc(100vh-104px)]") do
      rail
      editor_frame
    end
  end

  def rail
    div(
      class: "shrink-0 vmd:w-[224px] border-b vmd:border-b-0 vmd:border-r border-voodu-border bg-voodu-surface flex flex-col",
      data: {controller: "dashboard-rail", dashboard_rail_frame_value: EDITOR_FRAME}
    ) do
      rail_header
      div(class: "flex vmd:flex-col gap-1 px-2.5 pb-2.5 overflow-auto scrollbar-hidden") do
        if @dashboards.empty?
          span(class: "text-[11.5px] text-voodu-muted px-1 py-2") { "No dashboards yet — build your first one." }
        else
          @dashboards.each { |d| rail_item(d) }
        end
      end
    end
  end

  # rail_header — thin section label + a square "+" icon (tooltip "New
  # dashboard") instead of a full-width green button, so the rail starts with
  # the list, not a CTA, and the modal isn't a wall of green buttons.
  def rail_header
    div(class: "flex items-center justify-between gap-2 px-3 pt-3 pb-2") do
      span(class: "text-[11px] font-medium text-voodu-text-2 uppercase tracking-[0.06em]") { "Dashboards" }
      new_button
    end
  end

  def new_button
    a(
      href: new_metric_dashboard_path,
      data: {turbo_frame: EDITOR_FRAME, tooltip: "New dashboard"},
      "aria-label": "New dashboard",
      class: "inline-flex items-center justify-center w-7 h-7 shrink-0 border border-voodu-border bg-voodu-surface text-voodu-muted " \
             "hover:border-voodu-accent-line hover:bg-voodu-accent-dim hover:text-voodu-accent-2 transition-colors"
    ) { render Icon::PlusOutline.new(class: "w-4 h-4") }
  end

  # rail_item — links the editor frame to this dashboard. The active state
  # is data-attribute driven (`data-active`) so the dashboard-rail
  # controller can re-sync it on every editor-frame load — clicking a rail
  # item swaps only the inner frame, so a server-rendered class wouldn't
  # follow. `group` lets the label + icon recolor off the row's data-active.
  def rail_item(dashboard)
    active = dashboard.uuid == active_uuid

    a(
      href: edit_metric_dashboard_path(dashboard),
      data: {turbo_frame: EDITOR_FRAME, dashboard_rail_target: "item", uuid: dashboard.uuid, active: active.to_s},
      class: tokens(
        "group flex items-center gap-2.5 px-2.5 py-2 shrink-0 min-w-[150px] vmd:min-w-0 border vmd:border-y-0 vmd:border-r-0 vmd:border-l-2",
        "border-voodu-border-2 vmd:border-l-transparent hover:bg-voodu-surface-2",
        "data-[active=true]:border-voodu-accent-line data-[active=true]:bg-voodu-accent-dim vmd:data-[active=true]:border-l-voodu-accent"
      )
    ) do
      render(rail_icon(dashboard))
      div(class: "min-w-0") do
        span(class: "block text-[12.5px] truncate text-voodu-text group-data-[active=true]:text-voodu-accent-2 group-data-[active=true]:font-medium") { dashboard.name }
        span(class: "block text-[11px] text-voodu-muted truncate") { rail_subtext(dashboard) }
      end
    end
  end

  def rail_icon(dashboard)
    return Icon::BookmarkSolid.new(class: "w-3.5 h-3.5 text-voodu-accent-2 shrink-0") if dashboard.pinned

    Icon::Squares2x2Outline.new(class: "w-3.5 h-3.5 shrink-0 text-voodu-muted group-data-[active=true]:text-voodu-accent-2")
  end

  # active_uuid — which rail item shows as selected on first paint. Falls
  # back to whatever `initial_src` opens (pinned, else first) so the rail
  # highlight matches the editor that auto-loads when no dashboard was
  # explicitly requested.
  def active_uuid
    return @active_uuid if @active_uuid.present?

    (@dashboards.find(&:pinned) || @dashboards.first)&.uuid
  end

  def rail_subtext(dashboard)
    count = dashboard.panels_count
    base = "#{count} #{(count == 1) ? "panel" : "panels"}"
    dashboard.pinned ? "#{base} · pinned" : base
  end

  # editor_frame — fills the modal body height (flex column, min-h-0) so the
  # editor's own columns (the standalone Panels sidebar especially) can run
  # full-height instead of collapsing to content height.
  def editor_frame
    div(class: "flex-1 min-w-0 flex flex-col min-h-0") do
      turbo_frame_tag(EDITOR_FRAME, src: initial_src, class: "flex flex-col flex-1 min-h-0") do
        div(class: "flex items-center justify-center h-full p-10 text-[12.5px] text-voodu-muted") do
          render Components::UI::Spinner.new
        end
      end
    end
  end

  # initial_src — open straight into an editor: the explicitly requested
  # dashboard, else the pinned one, else the first. Empty island → the New form.
  def initial_src
    target = @dashboards.find { |d| d.uuid == @active_uuid } ||
      @dashboards.find(&:pinned) || @dashboards.first

    target ? edit_metric_dashboard_path(target) : new_metric_dashboard_path
  end
end
