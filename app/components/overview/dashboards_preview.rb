# frozen_string_literal: true

# Components::Overview::DashboardsPreview — the Overview's "Dashboards" summary
# card: the org's most recently configured metric dashboards (M2: dashboards are
# org-level). Each row opens that dashboard on /metrics; the header "See all"
# link goes to the dashboard manager. An empty org shows a "build one" CTA.
class Components::Overview::DashboardsPreview < Components::Base
  def initialize(dashboards:)
    @dashboards = dashboards
  end

  def view_template
    div(class: "border border-voodu-border bg-voodu-surface flex flex-col min-w-0") do
      header

      if @dashboards.empty?
        empty_state
      else
        div(class: "flex flex-col") { @dashboards.each { |dash| dash_row(dash) } }
      end
    end
  end

  private

  def header
    div(class: "flex items-center justify-between gap-2 px-3.5 py-2.5 border-b border-voodu-border") do
      div(class: "flex items-center gap-2 min-w-0") do
        render Icon::Squares2x2Outline.new(class: "w-4 h-4 shrink-0 text-voodu-muted")
        h2(class: "text-[13px] font-semibold text-voodu-text") { "Dashboards" }
      end

      a(href: metric_dashboards_path, class: "shrink-0 inline-flex items-center gap-1 text-[11.5px] text-voodu-link hover:underline") do
        span { "See all" }
        render Icon::ArrowRightOutline.new(class: "w-3 h-3")
      end
    end
  end

  def dash_row(dash)
    a(
      href: metrics_path(pid: dash.uuid),
      class: "flex items-center gap-3 px-3.5 py-2 border-b border-voodu-border-2 last:border-b-0 hover:bg-voodu-surface-2 transition-colors"
    ) do
      render row_icon(dash)

      div(class: "min-w-0 flex-1") do
        span(class: "block text-[12.5px] text-voodu-text truncate") { dash.name }
        span(class: "block text-[11px] text-voodu-muted truncate") { panels_label(dash) }
      end

      if dash.pinned
        span(class: "shrink-0 text-[10px] uppercase tracking-[0.05em] text-voodu-accent-2") { "pinned" }
      end
    end
  end

  def row_icon(dash)
    return Icon::BookmarkSolid.new(class: "w-3.5 h-3.5 shrink-0 text-voodu-accent-2") if dash.pinned

    Icon::Squares2x2Outline.new(class: "w-3.5 h-3.5 shrink-0 text-voodu-muted")
  end

  def panels_label(dash)
    count = dash.panels_count

    "#{count} #{(count == 1) ? "panel" : "panels"}"
  end

  def empty_state
    div(class: "px-3.5 py-6 flex flex-col items-center text-center gap-1.5") do
      span(class: "text-[12px] text-voodu-text-2") { "No dashboards yet" }
      a(href: new_metric_dashboard_path, class: "text-[11.5px] text-voodu-link hover:underline") { "Build your first dashboard" }
    end
  end
end
