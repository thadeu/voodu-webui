# frozen_string_literal: true

# LogsController — pod log viewer.
#
# `index` lists pods for the operator to pick.
# `show`  fetches the last N lines of one pod's logs via the PAT
#         plane. Wrapped in a Turbo Frame so the Stimulus polling
#         controller (app/javascript/controllers/polling_controller.js)
#         can reload it every 5s for a "live tail" feel without a
#         full-page reload.
class LogsController < ApplicationController
  def index
    @pods, @error = fetch_pods
    render Views::Logs::Index.new(**dashboard_context.merge(pods: @pods, error: @error, selected_pod: nil, logs: nil))
  end

  def show
    @pod_name = params[:name]
    @pods, @error = fetch_pods
    @logs = fetch_logs(@pod_name) unless @error

    # Turbo Frame refresh — when the polling controller reloads the
    # frame it sends `?frame=logs`; we render only the partial.
    if turbo_frame_request? || params[:frame] == "logs"
      render Views::Logs::Frame.new(pod_name: @pod_name, logs: @logs, error: @error)
    else
      render Views::Logs::Index.new(**dashboard_context.merge(
        pods: @pods, error: @error, selected_pod: @pod_name, logs: @logs
      ))
    end
  end

  private

  def fetch_pods
    return [[], nil] if voodu_client.nil?

    [voodu_client.pods["pods"] || [], nil]
  rescue Voodu::Client::Error => e
    [[], e]
  end

  def fetch_logs(name)
    voodu_client.logs(name, tail: 200)
  rescue Voodu::Client::Error => e
    @error = e
    nil
  end

  def turbo_frame_request?
    request.headers["Turbo-Frame"].present?
  end
end
