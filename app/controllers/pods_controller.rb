# frozen_string_literal: true

# PodsController — live container grid for the active island + the
# per-pod restart action.
#
# `index` fetches GET /api/pat/v1/pods every page load (Cmd-R from
# the operator is the polling cadence in M4; M5+ can wrap the grid
# in a Stimulus polling controller).
#
# `restart` POSTs to /api/pat/v1/pods/{name}/restart, then redirects
# back with a flash notice. Restart is intentionally not optimistic
# — the operator sees the actual server response before moving on.
class PodsController < ApplicationController
  def index
    @pods, @error = fetch_pods
    render Views::Pods::Index.new(**dashboard_context.merge(pods: @pods, error: @error))
  end

  def restart
    name = params[:name]

    if voodu_client.nil?
      redirect_to pods_path, alert: "No island selected." and return
    end

    voodu_client.restart(name)
    redirect_to pods_path, notice: "Restart triggered for #{name}."
  rescue Voodu::Client::Error => e
    redirect_to pods_path, alert: "Restart failed: #{e.message}"
  end

  private

  # fetch_pods returns [pods_array, error]. Exactly one of the two is
  # populated. View renders one of three states from this.
  def fetch_pods
    return [[], nil] if voodu_client.nil?

    [voodu_client.pods["pods"] || [], nil]
  rescue Voodu::Client::Error => e
    [[], e]
  end
end
