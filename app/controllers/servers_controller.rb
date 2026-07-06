# frozen_string_literal: true

# ServersController — register / list / delete the VPSs the WebUI
# talks to.
#
# This controller lives OUTSIDE the server-scoped routes (no
# `:server_key` in the URL) because:
#
#   - `/servers/new` must be reachable when the operator has zero
#     servers — there's no key to scope under yet.
#   - Listing + removing servers is the bootstrapping plane, not a
#     per-server operation.
#
# Switching between servers is no longer a controller action — it's
# a pure URL swap (the sidebar/topbar overwrites the `:server_key`
# segment with the target server's key). That's why the old `:select`
# member action is gone.
class ServersController < ApplicationController
  skip_before_action :require_server!

  before_action :set_server, only: [:edit, :update, :destroy]

  def index
    @servers = Server.order(:name).to_a

    render Views::Servers::Index.new(
      current_path: current_path,
      servers: @servers,
      active_tab: status_tab_param
    )
  end

  def new
    @server = Server.new
    render Views::Servers::New.new(current_path: current_path, server: @server, orgs: sorted_orgs)
  end

  def create
    @server = Server.new(server_params)

    # Round 1: validate fields locally (presence, format, etc.).
    # Don't even attempt to reach the agent if the form is bad —
    # avoids spending a network round-trip telling the operator
    # they typed an empty endpoint.
    unless @server.valid?
      render Views::Servers::New.new(current_path: current_path, server: @server, orgs: sorted_orgs),
        status: :unprocessable_entity
      return
    end

    # Round 2: preflight — probe the endpoint with the supplied PAT.
    # We do this BEFORE persisting so a typo'd token doesn't leave
    # a dead Server record in the sidebar. The operator gets the
    # real connection error class (auth vs network) inline in the
    # modal, matching the design beta's "Testing → Connection
    # failed" state.
    if (probe_error = ServerHealth.probe!(@server))
      render Views::Servers::New.new(
        current_path: current_path,
        server: @server,
        orgs: sorted_orgs,
        connection_error: probe_error
      ), status: :unprocessable_entity
      return
    end

    if @server.save
      # Warm the cache with the preflight result — the just-rendered
      # sidebar status pill is "online" without spending another HTTP
      # call on the next page render.
      ServerHealth.warm(@server, online: true)

      redirect_to server_root_path(org_id: @server.org.short_id, server_key: @server.key),
        notice: "Server #{@server.name} registered."
    else
      render Views::Servers::New.new(current_path: current_path, server: @server, orgs: sorted_orgs),
        status: :unprocessable_entity
    end
  end

  def edit
    render Views::Servers::Edit.new(
      current_path: current_path,
      server: @server,
      orgs: sorted_orgs,
      return_to: safe_return_to
    )
  end

  def update
    # PAT is sensitive — if the operator leaves the field blank on
    # edit we KEEP the stored value rather than overwriting it with
    # "". A literal blank submission would otherwise rotate to nil
    # and invalidate the connection without warning.
    attrs = server_params
    attrs.delete(:pat_ciphertext) if attrs[:pat_ciphertext].blank?

    @server.assign_attributes(attrs)

    unless @server.valid?
      render Views::Servers::Edit.new(current_path: current_path, server: @server, orgs: sorted_orgs, return_to: safe_return_to),
        status: :unprocessable_entity
      return
    end

    # Preflight again — endpoint or PAT may have changed and we don't
    # want a "successful save" that points at an unreachable host.
    if (probe_error = ServerHealth.probe!(@server))
      render Views::Servers::Edit.new(
        current_path: current_path,
        server: @server,
        orgs: sorted_orgs,
        return_to: safe_return_to,
        connection_error: probe_error
      ), status: :unprocessable_entity
      return
    end

    if @server.save
      ServerHealth.warm(@server, online: true)
      redirect_to (safe_return_to || servers_path), notice: "Server #{@server.name} updated."
    else
      render Views::Servers::Edit.new(current_path: current_path, server: @server, orgs: sorted_orgs, return_to: safe_return_to),
        status: :unprocessable_entity
    end
  end

  def destroy
    @server.destroy
    ServerHealth.invalidate(@server)
    redirect_to servers_path, notice: "Server removed."
  end

  private

  # set_server — Rails packs `to_param` into `:id`, and we overrode
  # Server#to_param to return `key` (so URLs read /servers/a3f9k2
  # instead of /servers/42). That means `params[:id]` here is the
  # key, not the integer id — lookup must be by key.
  def set_server
    @server = Server.find_by!(key: params[:id])
  end

  # safe_return_to — accepts a ?return_to= path query param + sanity
  # checks it. Only same-origin RELATIVE paths starting with `/`
  # are accepted, blocking open-redirect attacks (an attacker
  # crafting `?return_to=https://evil.example/...` couldn't steer
  # the post-save redirect off-site). nil falls back to the
  # default in the action (usually servers_path).
  def safe_return_to
    p = params[:return_to].to_s
    (p.start_with?("/") && !p.start_with?("//")) ? p : nil
  end

  def server_params
    # region + infra are free-text metadata the operator types at
    # registration — they don't drive any controller behavior, they
    # just decorate the topbar ("fra1 · hetzner"). Both nullable;
    # the topbar collapses chips that are blank.
    params.require(:server).permit(:name, :endpoint, :pat_ciphertext, :region, :infra, :org_id)
  end

  # sorted_orgs — the org list feeding the registration form's dropdown +
  # the inline org manager. Empty on first run (the form shows the "create
  # your first org" CTA).
  def sorted_orgs
    Org.order(:name).to_a
  end

  # status_tab_param — coerce ?status= into the symbol the view
  # expects. Anything unknown falls back to :all.
  def status_tab_param
    case params[:status]
    when "online" then :online
    when "offline" then :offline
    else :all
    end
  end
end
