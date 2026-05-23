# frozen_string_literal: true

# ApplicationController — root of the controller hierarchy.
#
# Exposes `current_path` to every subclass so the dashboard layout
# (which highlights the active sidebar item) can be rendered without
# each controller having to re-derive it from `request`.
#
# M-future: when auth lands this is where `current_operator` etc.
# get attached.
class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges,
  # import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  private

  # Returns the current request path (e.g. "/pods", "/logs/foo").
  # Views forward this to Components::Layouts::Dashboard so the
  # sidebar can mark the right nav item active.
  def current_path
    request.path
  end

  # all_islands — every island the operator has registered. Sorted
  # by name so sidebar order is deterministic. Used by every screen
  # that renders the dashboard layout (the sidebar list).
  def all_islands
    @all_islands ||= Island.order(:name).to_a
  end

  # current_island — the one the operator is currently focused on.
  # Selection persists in the session cookie; falls back to the first
  # registered island so a fresh visit immediately has context.
  def current_island
    return @current_island if defined?(@current_island)

    @current_island = if session[:current_island_id]
                        Island.find_by(id: session[:current_island_id]) || all_islands.first
                      else
                        all_islands.first
                      end
  end

  # voodu_client — Faraday-backed wrapper around the current_island's
  # PAT plane. Controllers that need to hit the controller use this:
  #
  #   voodu_client.pods
  #   voodu_client.restart(pod_name)
  #
  # Returns nil when no island is registered yet — callers should
  # render an empty-state in that case rather than crash.
  def voodu_client
    return nil unless current_island

    @voodu_client ||= Voodu::Client.new(current_island)
  end

  # dashboard_context — the kwargs every Phlex view passes into
  # Components::Layouts::Dashboard.new. Single point of change when
  # the layout needs more context (M5 adds e.g. recent_notifications).
  def dashboard_context
    {
      current_path:   current_path,
      islands:        all_islands,
      current_island: current_island
    }
  end

  helper_method :current_path, :all_islands, :current_island, :voodu_client, :dashboard_context
end
