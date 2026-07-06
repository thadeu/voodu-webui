# frozen_string_literal: true

# Views::Logs::Index — multi-source log tail (`/logs`).
# Streams from every known pod profile.
class Views::Logs::Index < Views::Base
  def initialize(current_path:, servers: [], current_server: nil, updated_at: nil, pods: [])
    @current_path = current_path
    @servers = servers
    @current_server = current_server
    @updated_at = updated_at
    @pods = pods
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers,
      current_server: @current_server, updated_at: @updated_at,
      breadcrumb: @current_server && overview_crumbs(
        {label: "Logs", href: logs_analytics_path(server_key: @current_server.key)},
        {label: "Follow"}
      )
    ) do
      if @current_server.nil?
        render Components::UI::NoServerState.new
      else
        render Components::Logs::Page.new(pod_name: nil, pods: @pods)
      end
    end
  end
end
