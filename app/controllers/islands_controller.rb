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

  # POST /islands/:id/select — UI affordance to switch islands without
  # navigating away from the current page (M5 wires a dropdown to this).
  def select
    session[:current_island_id] = @island.id
    redirect_back fallback_location: root_path
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
    params.require(:island).permit(:name, :endpoint, :pat_ciphertext)
  end
end
