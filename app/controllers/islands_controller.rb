# frozen_string_literal: true

# IslandsController — register / list / select / delete the VPSs the
# WebUI talks to. The "Add island" form is the single onboarding
# touch point: operator pastes endpoint URL + PAT, hits create, and
# the sidebar lights up.
class IslandsController < ApplicationController
  before_action :set_island, only: [:show, :destroy, :select]

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
      session[:current_island_id] = @island.id
      redirect_to root_path, notice: "Island #{@island.name} registered."
    else
      render Views::Islands::New.new(current_path: current_path, island: @island), status: :unprocessable_entity
    end
  end

  def show
    session[:current_island_id] = @island.id
    redirect_to root_path
  end

  # POST /islands/:id/select — switch to a different island. Always
  # lands on Overview (root_path) rather than preserving the current
  # page because:
  #
  #   1. The per-page snapshots (pods table, logs, pod detail) are
  #      island-scoped — staying on /pods after a switch shows a
  #      brief "loading"/cold-cache state for an island the
  #      operator hasn't touched recently.
  #   2. Overview is the always-warm landing page that fetches
  #      /system + /pods on every render — guaranteed live data
  #      for the new island in one round-trip.
  #   3. Mental model match: "switching island" reads as "start
  #      over on this island", not "translate my current path to
  #      the other island."
  def select
    session[:current_island_id] = @island.id
    redirect_to root_path
  end

  def destroy
    @island.destroy
    session.delete(:current_island_id) if session[:current_island_id] == @island.id
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
