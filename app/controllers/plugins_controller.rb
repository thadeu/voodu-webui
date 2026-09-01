# frozen_string_literal: true

# The plugin marketplace for one server.
#
# Plugins live on the controller's disk, so this screen is a view onto the box
# rather than onto our database — nothing is persisted here. What we keep is a
# short cache (PluginsData::TTL) so a page refresh does not cross the network
# for a list that changes rarely, invalidated whenever this installation itself
# changes something.
#
# AUTHORIZATION IS DELIBERATELY TIGHTER HERE than on the neighbouring screens.
# Restarting a pod is gated by nothing today; installing a plugin clones a
# repository and runs its lifecycle hooks as the controller's user, which is
# arbitrary code execution on the operator's machine. That is not a day-to-day
# read, so writes need `manage_servers`. Reading the list stays open to anyone
# who can already see the server.
class PluginsController < ApplicationController
  # The whole screen, not only its writes. `index` was open to members, so
  # hiding the nav item would have produced the opposite inconsistency to the
  # one being fixed — a door not drawn but still openable by typing the URL.
  # A read-only marketplace is not a feature anybody asked for: this screen
  # exists to install, update and remove.
  authorize :manage_servers

  # Matches the frame in Views::Plugins::Index, which polls so an install that
  # is still running resolves itself.
  FRAME = "plugins-grid"

  def index
    @data = current_server &&
      PluginsData.new(server: current_server, page: params[:page], sort: params[:sort])

    if request.headers["Turbo-Frame"] == FRAME
      render Views::Plugins::Frame.new(data: @data), layout: false
    else
      render Views::Plugins::Index.new(**dashboard_context.merge(data: @data))
    end
  end

  # Starts an install. The controller answers 202 and keeps working, so this
  # redirects straight back — the card reports the outcome on the next poll.
  def create
    source = params[:source].to_s.strip

    return refuse_with("Enter a plugin to install, like thadeu/voodu-redis.") if source.blank?
    return refuse_with("No server selected.") if voodu_client.nil?

    voodu_client.install_plugin(source, version: params[:version])
    PluginsData.expire!(current_server)

    redirect_to plugins_path, notice: "Installing #{source} — this page will show it when it lands."
  rescue Voodu::Client::Error => e
    refuse_with(install_failure_message(source, e))
  end

  def destroy
    name = params[:name].to_s

    return refuse_with("No server selected.") if voodu_client.nil?

    voodu_client.remove_plugin(name)
    PluginsData.expire!(current_server)

    redirect_to plugins_path, notice: "#{name} was uninstalled."
  rescue Voodu::Client::Error => e
    refuse_with("Could not uninstall #{name}: #{e.message}")
  end

  private

  def refuse_with(message)
    redirect_to plugins_path, alert: message
  end

  # The two failures an operator actually hits, named. A 409 means they clicked
  # twice (or have the page open elsewhere) and is not an error worth alarming
  # them about; a 403 means the PAT this server was registered with cannot do
  # this, which is a fix on the box, not here.
  def install_failure_message(source, error)
    message = error.message.to_s

    return "#{source} is already installing." if message.include?("already running")

    if message.include?("403") || message.downcase.include?("scope")
      return "This server's token cannot install plugins — it needs the actions scope."
    end

    "Could not start the install: #{message}"
  end
end
