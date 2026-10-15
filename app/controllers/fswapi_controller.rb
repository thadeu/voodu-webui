# frozen_string_literal: true

# FswapiController — the FreeSWITCH page (voodu-fswapi plugin). One action:
# the full page, or only its polled frame when Turbo asks for it.
class FswapiController < ApplicationController
  FRAME = "fswapi-live"

  # The page exists only where the plugin does. The sidebar hides the item; this
  # closes the door for a typed or bookmarked URL too, after an uninstall.
  before_action :require_fswapi_plugin!

  def index
    data = FswapiPageData.new(server: current_server, view: params[:view], q: params[:q])

    if request.headers["Turbo-Frame"] == FRAME
      render Views::Fswapi::Frame.new(data: data), layout: false
    else
      render Views::Fswapi::Index.new(**dashboard_context.merge(data: data))
    end
  end

  private

  def require_fswapi_plugin!
    return if current_server&.plugin_installed?("fswapi")

    redirect_to server_root_path, alert: "FreeSWITCH is not available on this server. Install the voodu-fswapi plugin to see it."
  end
end
