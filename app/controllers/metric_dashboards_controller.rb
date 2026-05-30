# frozen_string_literal: true

# MetricDashboardsController — CRUD for the operator's saved metric
# dashboards, plus pin/unpin. Tenant-scoped (lives under /:tenant_key)
# so current_island flows through naturally.
#
# Surfaces:
#   - index / new / edit → rendered into the right drawer (embed mode,
#     layout: false) by Components::UI::Drawer.
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
    @dashboards = current_island.metric_dashboards.order(:name).to_a

    render Views::MetricDashboards::List.new(
      island:     current_island,
      dashboards: @dashboards
    ), layout: false
  end

  def new
    @dashboard = current_island.metric_dashboards.new

    render Views::MetricDashboards::Form.new(
      island:    current_island,
      dashboard: @dashboard,
      pods:      compact_pods,
      embed:     true
    ), layout: false
  end

  def create
    @dashboard = current_island.metric_dashboards.new(name: dashboard_params[:name])
    @dashboard.panels = parsed_panels

    if @dashboard.save
      redirect_to metrics_path(pid: @dashboard.uuid),
                  notice: "Dashboard #{@dashboard.name} created."
    else
      render_form_full_page(status: :unprocessable_entity)
    end
  end

  def edit
    render Views::MetricDashboards::Form.new(
      island:    current_island,
      dashboard: @dashboard,
      pods:      compact_pods,
      embed:     true
    ), layout: false
  end

  def update
    @dashboard.name   = dashboard_params[:name]
    @dashboard.panels = parsed_panels

    if @dashboard.save
      redirect_to metrics_path(pid: @dashboard.uuid),
                  notice: "Dashboard #{@dashboard.name} updated."
    else
      render_form_full_page(status: :unprocessable_entity)
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
    @dashboard = current_island.metric_dashboards.find_by!(uuid: params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to metrics_path, alert: "Dashboard was not found."
  end

  # render_form_full_page — re-render the builder as a standalone page
  # (with dashboard chrome) after a validation error, so the operator
  # sees inline errors with their entered name + panels intact.
  def render_form_full_page(status:)
    render Views::MetricDashboards::Form.new(
      island:         current_island,
      dashboard:      @dashboard,
      pods:           compact_pods,
      embed:          false,
      current_path:   current_path,
      islands:        all_islands,
      current_island: current_island
    ), status: status
  end

  def compact_pods
    IslandPods.compact(voodu_client, current_island)
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
