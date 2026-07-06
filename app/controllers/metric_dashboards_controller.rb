# frozen_string_literal: true

# MetricDashboardsController — CRUD for the operator's saved metric
# dashboards, plus pin/unpin. Tenant-scoped (lives under /:tenant_key)
# so current_island flows through naturally.
#
# Surfaces:
#   - index → the manage MODAL (Views::MetricDashboards::Manage): a full-page
#     master-detail dialog (rail of dashboards + an editor turbo-frame).
#   - new / edit → the editor (Views::MetricDashboards::Form, layout: false)
#     swapped into the modal's "dashboard-editor" frame.
#   - create / update    → full-page POST (form is data-turbo:false,
#     same as IslandsController). Success redirects to the rendered
#     dashboard (/metrics?dashboard=<id>); a validation error re-renders
#     the builder as a full page (embed: false) with inline errors,
#     preserving the entered name + panels.
#   - pin / unpin        → toggle the single per-island default and
#     bounce back to /metrics.
class MetricDashboardsController < ApplicationController
  before_action :set_dashboard, only: [:edit, :update, :destroy, :pin, :unpin]

  def index
    @dashboards = current_org.metric_dashboards.order(:name).to_a

    # Full-page master-detail modal over the dashboard chrome (no layout:false
    # — the view brings its own chrome). The right frame lazy-loads an editor.
    render Views::MetricDashboards::Manage.new(
      island: current_island,
      dashboards: @dashboards,
      current_path: current_path,
      islands: all_islands,
      current_island: current_island,
      active_uuid: params[:edit].presence
    )
  end

  def new
    @dashboard = current_org.metric_dashboards.new

    render Views::MetricDashboards::Form.new(
      island: current_island,
      dashboard: @dashboard,
      island_pods: org_island_pods,
      embed: true,
      return_to: referer_return_to
    ), layout: false
  end

  def create
    @dashboard = current_org.metric_dashboards.new(name: dashboard_params[:name])
    @dashboard.panels = parsed_panels

    if @dashboard.save
      # Stay in the manager (don't auto-close): land back on this dashboard's
      # editor with a fresh rail. Closing the modal (X/Esc) is the operator's
      # call.
      redirect_to(metric_dashboards_path(edit: @dashboard.uuid),
        notice: "Dashboard #{@dashboard.name} created.")
    else
      render_form_errors
    end
  end

  def edit
    render Views::MetricDashboards::Form.new(
      island: current_island,
      dashboard: @dashboard,
      island_pods: org_island_pods,
      embed: true,
      return_to: referer_return_to
    ), layout: false
  end

  def update
    @dashboard.name = dashboard_params[:name]
    @dashboard.panels = parsed_panels

    if @dashboard.save
      # Stay in the manager (don't auto-close) — reopen this dashboard's
      # editor with a fresh rail rather than bouncing to /metrics.
      redirect_to(metric_dashboards_path(edit: @dashboard.uuid),
        notice: "Dashboard #{@dashboard.name} updated.")
    else
      render_form_errors
    end
  end

  def destroy
    @dashboard.destroy
    redirect_to metrics_path, notice: "Dashboard removed."
  end

  def pin
    @dashboard.pin!
    redirect_to metrics_path(pid: @dashboard.uuid)
  end

  def unpin
    @dashboard.unpin!
    redirect_to metrics_path
  end

  private

  # set_dashboard — scope the lookup to the current island so one
  # island can't address another's dashboards by id. A stale id (the
  # operator bookmarked a since-deleted dashboard) bounces to /metrics
  # rather than 500ing.
  def set_dashboard
    @dashboard = current_org.metric_dashboards.find_by!(uuid: params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to metrics_path, alert: "Dashboard was not found."
  end

  # render_form_errors — on a validation error, re-render the builder
  # IN PLACE (the "dashboards-panel" turbo-frame, wherever it lives —
  # the switcher drawer or a full-page builder) so the error stays put
  # instead of blowing the form out to the page content. The form
  # submits with turbo_frame "_top" (success → full-page redirect to the
  # new dashboard), but a turbo_stream response targets the frame by id
  # regardless, so the errored form swaps back into the drawer.
  # HTML fallback (no-JS) keeps the old full-page render.
  def render_form_errors
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          Views::MetricDashboards::Form::FRAME_ID,
          Views::MetricDashboards::Form.new(
            island: current_island,
            dashboard: @dashboard,
            island_pods: org_island_pods,
            embed: true,
            return_to: return_to_path
          )
        ), status: :unprocessable_entity
      end
      format.html { render_form_full_page(status: :unprocessable_entity) }
    end
  end

  # render_form_full_page — re-render the builder as a standalone page
  # (with dashboard chrome) after a validation error, so the operator
  # sees inline errors with their entered name + panels intact.
  def render_form_full_page(status:)
    render Views::MetricDashboards::Form.new(
      island: current_island,
      dashboard: @dashboard,
      island_pods: org_island_pods,
      embed: false,
      current_path: current_path,
      islands: all_islands,
      current_island: current_island,
      return_to: return_to_path
    ), status: status
  end

  # referer_return_to — the /metrics URL the builder was opened from,
  # taken from the Referer header (the drawer edit/new fetch carries the
  # operator's current page). Rendered into a hidden field so the save
  # can route back to it.
  def referer_return_to
    internal_metrics_path(request.referer)
  end

  # return_to_path — the sanitized return target submitted with the form.
  def return_to_path
    internal_metrics_path(params[:return_to])
  end

  # internal_metrics_path — sanitize a candidate URL down to a same-app
  # /metrics path (+ query), or nil. Open-redirect guard: only a relative
  # path on THIS tenant's metrics route is accepted (cross-tenant or
  # absolute external URLs are rejected).
  def internal_metrics_path(url)
    return nil if url.blank?

    uri = URI.parse(url)
    path = uri.path.to_s
    return nil unless path.start_with?("/") && !path.start_with?("//")
    return nil unless path == metrics_path

    uri.query.present? ? "#{path}?#{uri.query}" : path
  rescue URI::InvalidURIError
    nil
  end

  # org_island_pods — [[island, [compact pods]], …] for EVERY server in the
  # org (M2). The builder enumerates workloads / hep3 readers across all of
  # them so a dashboard panel can read from any server (each panel carries its
  # island_id). One compact-pods fetch per server (cached 60s); the org is the
  # isolation boundary, so no server outside current_org is ever listed.
  def org_island_pods
    @org_island_pods ||= current_org.islands.order(:name).map do |island|
      [island, IslandPods.compact(Voodu::Client.new(island), island)]
    end
  end

  def dashboard_params
    # `panels` is a JSON string from the builder's hidden field —
    # permit it as a scalar so it doesn't log an Unpermitted warning;
    # parsed_panels does the actual decode.
    params.require(:metric_dashboard).permit(:name, :panels)
  end

  # parsed_panels — the builder serializes its in-memory panel list to
  # a JSON string in a hidden `panels` field (strong params can't
  # whitelist an arbitrary array-of-hashes cleanly, so we read it raw
  # and parse). Malformed JSON → [] → the model's panels_well_formed
  # validation surfaces "must have at least one panel"-style feedback.
  def parsed_panels
    raw = params.dig(:metric_dashboard, :panels)
    return [] if raw.blank?

    parsed = JSON.parse(raw)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    []
  end
end
