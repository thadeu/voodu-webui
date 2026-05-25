# frozen_string_literal: true

# IslandsController — register / list / delete the VPSs the WebUI
# talks to.
#
# This controller lives OUTSIDE the tenant-scoped routes (no
# `:tenant_key` in the URL) because:
#
#   - `/islands/new` must be reachable when the operator has zero
#     islands — there's no key to scope under yet.
#   - Listing + removing islands is the bootstrapping plane, not a
#     per-tenant operation.
#
# Switching between islands is no longer a controller action — it's
# a pure URL swap (the sidebar/topbar overwrites the `:tenant_key`
# segment with the target island's key). That's why the old `:select`
# member action is gone.
class IslandsController < ApplicationController
  skip_before_action :require_tenant!

  before_action :set_island, only: [:edit, :update, :destroy]

  def index
    @islands = Island.order(:name).to_a

    render Views::Islands::Index.new(
      current_path: current_path,
      islands:      @islands,
      active_tab:   status_tab_param
    )
  end

  def new
    @island = Island.new
    render Views::Islands::New.new(current_path: current_path, island: @island)
  end

  def create
    @island = Island.new(island_params)

    # Round 1: validate fields locally (presence, format, etc.).
    # Don't even attempt to reach the agent if the form is bad —
    # avoids spending a network round-trip telling the operator
    # they typed an empty endpoint.
    unless @island.valid?
      render Views::Islands::New.new(current_path: current_path, island: @island),
             status: :unprocessable_entity
      return
    end

    # Round 2: preflight — probe the endpoint with the supplied PAT.
    # We do this BEFORE persisting so a typo'd token doesn't leave
    # a dead Island record in the sidebar. The operator gets the
    # real connection error class (auth vs network) inline in the
    # modal, matching the design beta's "Testing → Connection
    # failed" state.
    if (probe_error = IslandHealth.probe!(@island))
      render Views::Islands::New.new(
        current_path:     current_path,
        island:           @island,
        connection_error: probe_error
      ), status: :unprocessable_entity
      return
    end

    if @island.save
      # Warm the cache with the preflight result — the just-rendered
      # sidebar status pill is "online" without spending another HTTP
      # call on the next page render.
      IslandHealth.warm(@island, online: true)

      redirect_to tenant_root_path(tenant_key: @island.key),
                  notice: "Server #{@island.name} registered."
    else
      render Views::Islands::New.new(current_path: current_path, island: @island),
             status: :unprocessable_entity
    end
  end

  def edit
    render Views::Islands::Edit.new(
      current_path: current_path,
      island:       @island,
      return_to:    safe_return_to
    )
  end

  def update
    # PAT is sensitive — if the operator leaves the field blank on
    # edit we KEEP the stored value rather than overwriting it with
    # "". A literal blank submission would otherwise rotate to nil
    # and invalidate the connection without warning.
    attrs = island_params
    attrs.delete(:pat_ciphertext) if attrs[:pat_ciphertext].blank?

    @island.assign_attributes(attrs)

    unless @island.valid?
      render Views::Islands::Edit.new(current_path: current_path, island: @island, return_to: safe_return_to),
             status: :unprocessable_entity
      return
    end

    # Preflight again — endpoint or PAT may have changed and we don't
    # want a "successful save" that points at an unreachable host.
    if (probe_error = IslandHealth.probe!(@island))
      render Views::Islands::Edit.new(
        current_path:     current_path,
        island:           @island,
        return_to:        safe_return_to,
        connection_error: probe_error
      ), status: :unprocessable_entity
      return
    end

    if @island.save
      IslandHealth.warm(@island, online: true)
      redirect_to (safe_return_to || islands_path), notice: "Server #{@island.name} updated."
    else
      render Views::Islands::Edit.new(current_path: current_path, island: @island, return_to: safe_return_to),
             status: :unprocessable_entity
    end
  end

  def destroy
    @island.destroy
    IslandHealth.invalidate(@island)
    redirect_to islands_path, notice: "Server removed."
  end

  private

  # set_island — Rails packs `to_param` into `:id`, and we overrode
  # Island#to_param to return `key` (so URLs read /islands/a3f9k2
  # instead of /islands/42). That means `params[:id]` here is the
  # key, not the integer id — lookup must be by key.
  def set_island
    @island = Island.find_by!(key: params[:id])
  end

  # safe_return_to — accepts a ?return_to= path query param + sanity
  # checks it. Only same-origin RELATIVE paths starting with `/`
  # are accepted, blocking open-redirect attacks (an attacker
  # crafting `?return_to=https://evil.example/...` couldn't steer
  # the post-save redirect off-site). nil falls back to the
  # default in the action (usually islands_path).
  def safe_return_to
    p = params[:return_to].to_s
    p.start_with?("/") && !p.start_with?("//") ? p : nil
  end

  def island_params
    # region + infra are free-text metadata the operator types at
    # registration — they don't drive any controller behavior, they
    # just decorate the topbar ("fra1 · hetzner"). Both nullable;
    # the topbar collapses chips that are blank.
    params.require(:island).permit(:name, :endpoint, :pat_ciphertext, :region, :infra)
  end

  # status_tab_param — coerce ?status= into the symbol the view
  # expects. Anything unknown falls back to :all.
  def status_tab_param
    case params[:status]
    when "online"  then :online
    when "offline" then :offline
    else                :all
    end
  end
end
