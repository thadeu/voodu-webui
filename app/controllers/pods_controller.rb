# frozen_string_literal: true

# PodsController — pod listing, detail, and restart action.
#
#   GET  /pods             → list (reuses OverviewData's pods view +
#                            adds page header with status counts +
#                            scope summary)
#   GET  /pods/:name       → bypass JSON dump of the container — Spec
#                            / Network / Env / Labels cards driven by
#                            PodDetailData
#   POST /pods/:name/restart → triggers /api/pat/v1/pods/:name/restart,
#                            redirects with toast
class PodsController < ApplicationController
  def index
    @data = OverviewData.new(
      voodu_client, current_island,
      force_refresh: params[:refresh].present?
    )

    render Views::Pods::Index.new(
      **dashboard_context.merge(
        data: @data,
        active_tab: tab_param,
        updated_at: @data.updated_at
      )
    )
  end

  def show
    name = params[:name]
    @data = PodDetailData.new(
      voodu_client, current_island, name,
      force_refresh: params[:refresh].present?
    )

    view = Views::Pods::Show.new(
      **dashboard_context.merge(
        data: @data,
        updated_at: @data.updated_at,
        drawer: drawer_embed?
      )
    )

    # Embed mode = drawer fetch → bare body markup, no Rails layout.
    drawer_embed? ? render(view, layout: false) : render(view)
  end

  def restart
    name = params[:name]
    back = request.referer || pods_path

    if voodu_client.nil?
      redirect_to back, alert: "No island selected." and return
    end

    voodu_client.restart(name)
    # Restart invalidates whatever the detail page cached — flush so
    # the operator's next reload reflects the new state immediately.
    Rails.cache.delete("voodu:pod_detail:v1:island:#{current_island.id}:pod:#{name}")
    Rails.cache.delete("voodu:overview:v1:island:#{current_island.id}")

    redirect_to back, notice: "Restart triggered for #{name}."
  rescue Voodu::Client::Error => e
    redirect_to back, alert: "Restart failed: #{e.message}"
  end

  private

  def tab_param
    case params[:status]
    when "running" then :running
    when "restarting" then :restarting
    when "stopped" then :stopped
    else :all
    end
  end
end
