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

  before_action :set_island, only: [:destroy]

  def index
    @islands = Island.order(:name)
    render Views::Islands::Index.new(current_path: current_path, islands: @islands)
  end

  def new
    @island = Island.new
    render Views::Islands::New.new(current_path: current_path, island: @island)
  end

  def create
    @island = Island.new(island_params)
    if @island.save
      # Land the operator on the new island's overview. The URL itself
      # encodes the island context — no session write needed.
      redirect_to tenant_root_path(tenant_key: @island.key),
                  notice: "Island #{@island.name} registered."
    else
      render Views::Islands::New.new(current_path: current_path, island: @island),
             status: :unprocessable_entity
    end
  end

  def destroy
    @island.destroy
    redirect_to islands_path, notice: "Island removed."
  end

  private

  def set_island
    @island = Island.find(params[:id])
  end

  def island_params
    # region + infra are free-text metadata the operator types at
    # registration — they don't drive any controller behavior, they
    # just decorate the topbar ("fra1 · hetzner"). Both nullable;
    # the topbar collapses chips that are blank.
    params.require(:island).permit(:name, :endpoint, :pat_ciphertext, :region, :infra)
  end
end
