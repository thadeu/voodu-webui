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
  # Reading a pod is a member's business; stopping and recreating one is not.
  # This action had NO authorization at all — every member with reach into the
  # org could restart any container on any server they could see, interrupting
  # in-flight traffic on somebody else's production. Hiding the button would
  # not have touched that: the form posts to a path anybody can type.
  #
  # :manage_servers, the same capability the rest of "operate this server"
  # sits behind.
  authorize :manage_servers, only: :restart

  def index
    @data = OverviewData.new(voodu_client, current_server)

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
    @data = PodDetailData.new(voodu_client, current_server, name)

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
      redirect_to back, alert: "No server selected." and return
    end

    voodu_client.restart(name)
    # Restart invalidates whatever the detail page cached — flush so
    # the operator's next reload reflects the new state immediately.
    Rails.cache.delete("voodu:pod_detail:v1:server:#{current_server.id}:pod:#{name}")
    Rails.cache.delete("voodu:overview:v1:server:#{current_server.id}")

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
