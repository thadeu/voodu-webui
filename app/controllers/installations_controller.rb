# frozen_string_literal: true

# Settings that belong to the container, not to a server.
#
# The licence and the sign-in method configure the whole installation, so they
# live at a top-level URL like /servers and /orgs do — the same level the
# POST routes for them were always at. Reaching them through
# /:org_id/:server_key/settings meant an operator with no server registered
# could not open their own licence.
class InstallationsController < ApplicationController
  skip_before_action :require_server!

  def show
    render Views::Installations::Show.new(current_path: request.path, servers: all_servers)
  end
end
