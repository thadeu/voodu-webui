# frozen_string_literal: true

# Views::MetricDashboards::List — the switcher drawer body. Lists the
# island's saved dashboards with pin / edit / delete affordances and a
# "New dashboard" button. (Host is a panel SOURCE inside the builder,
# not a standalone entry — metrics are dashboard-driven.)
#
# Wrapped in a turbo_frame ("dashboards-panel") so the New / Edit links
# swap the builder into THIS frame (in-drawer navigation), while the
# switch + pin + delete actions break out to a full-page navigation
# (data-turbo:false) — those land the operator on the rendered
# dashboard or back on /metrics.
class Views::MetricDashboards::List < Views::Base
  FRAME_ID = "dashboards-panel"

  def initialize(island:, dashboards:)
    @island     = island
    @dashboards = dashboards
  end

  def view_template
    turbo_frame_tag(FRAME_ID) do
      div(class: "flex flex-col") do
        header_row
        if @dashboards.empty?
          empty_state
        else
          div(class: "flex flex-col") { @dashboards.each { |d| dashboard_row(d) } }
        end
      end
    end
  end

  private

  def header_row
    div(class: "flex items-center justify-between gap-2 px-4 py-3 border-b border-voodu-border") do
      div(class: "flex items-center gap-2 min-w-0") do
        render Icon::Squares2x2Outline.new(class: "w-4 h-4 text-voodu-muted shrink-0")
        span(class: "text-[13px] font-semibold text-voodu-text truncate") { "Dashboards" }
      end

      a(
        href: new_metric_dashboard_path,
        class: "inline-flex items-center gap-1.5 px-2.5 h-8 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px] font-medium hover:bg-voodu-surface-2 hover:text-voodu-text shrink-0"
      ) do
        render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
        span { "New" }
      end
    end
  end

  def dashboard_row(dashboard)
    div(class: "flex items-center gap-1 px-2 py-2 border-b border-voodu-border-2 hover:bg-voodu-surface-2") do
      a(
        href: metrics_path(pid: dashboard.uuid),
        data: { turbo_frame: "_top" },
        class: "flex items-center gap-2.5 px-2 py-1 min-w-0 flex-1"
      ) do
        if dashboard.pinned
          render Icon::BookmarkSolid.new(class: "w-3.5 h-3.5 text-voodu-accent-2 shrink-0")
        else
          render Icon::Squares2x2Outline.new(class: "w-4 h-4 text-voodu-muted shrink-0")
        end

        div(class: "min-w-0 flex-1") do
          div(class: "text-[12.5px] font-medium text-voodu-text truncate") { dashboard.name }
          div(class: "text-[11px] text-voodu-muted") do
            plain "#{dashboard.panels_count} #{dashboard.panels_count == 1 ? 'panel' : 'panels'}"
            if dashboard.pinned
              plain " · "
              span(class: "text-voodu-accent-2") { "pinned" }
            end
          end
        end
      end

      div(class: "flex items-center gap-0.5 shrink-0") do
        pin_button(dashboard)
        edit_link(dashboard)
        delete_button(dashboard)
      end
    end
  end

  # pin_button — native (data-turbo:false) POST toggling the single
  # per-island pin. Redirects to the dashboard (pin) or /metrics (unpin)
  # full-page, leaving the drawer.
  def pin_button(dashboard)
    action = dashboard.pinned ? unpin_metric_dashboard_path(dashboard) : pin_metric_dashboard_path(dashboard)

    form(action: action, method: "post", data: { turbo_frame: "_top" }, class: "inline-flex") do
      input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)
      button(
        type:  "submit",
        title: dashboard.pinned ? "Unpin" : "Pin as default",
        "aria-label": dashboard.pinned ? "Unpin #{dashboard.name}" : "Pin #{dashboard.name}",
        class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface shrink-0"
      ) do
        if dashboard.pinned
          render Icon::BookmarkSolid.new(class: "w-3.5 h-3.5 text-voodu-accent-2")
        else
          render Icon::BookmarkOutline.new(class: "w-3.5 h-3.5")
        end
      end
    end
  end

  # edit_link — frame navigation (Turbo on) so the builder swaps into
  # this same drawer frame instead of a full-page jump.
  def edit_link(dashboard)
    a(
      href: edit_metric_dashboard_path(dashboard),
      title: "Edit",
      "aria-label": "Edit #{dashboard.name}",
      class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface shrink-0"
    ) { render Icon::PencilSquareOutline.new(class: "w-3.5 h-3.5") }
  end

  def delete_button(dashboard)
    render Components::UI::Confirmable.new(
      title:         "Delete dashboard",
      message:       "Permanently delete \"#{dashboard.name}\"? This can't be undone.",
      confirm_label: "Delete",
      danger:        true,
      icon:          :TrashOutline,
      # Break out of the drawer's "dashboards-panel" turbo_frame so the
      # delete redirect lands on /metrics (full page) instead of 404ing
      # the missing frame ("Content missing").
      turbo_frame:   "_top",
      form:          { action: metric_dashboard_path(dashboard), method: :delete },
      trigger:       {
        class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-red hover:bg-voodu-surface shrink-0",
        title: "Delete",
        "aria-label": "Delete #{dashboard.name}"
      }
    ) do
      render Icon::TrashOutline.new(class: "w-3.5 h-3.5")
    end
  end

  def empty_state
    div(class: "px-4 py-8 flex flex-col items-center gap-2 text-center") do
      render Icon::Squares2x2Outline.new(class: "w-8 h-8 text-voodu-muted-2")
      div(class: "text-[12.5px] text-voodu-text-2 font-medium") { "No dashboards yet" }
      div(class: "text-[11.5px] text-voodu-muted max-w-[240px]") do
        plain "Build one to watch host + pod metrics together on a single screen."
      end
    end
  end
end
