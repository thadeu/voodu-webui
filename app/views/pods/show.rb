# frozen_string_literal: true

# Views::Pods::Show — single-pod detail dump.
#
# Layout follows the design beta exactly:
#   - back link → header (title + meta chips + actions)
#   - 4 stat cards (CPU / Memory / NetRx / NetTx)
#   - Spec card | Network card (2-col grid on vmd+)
#   - Environment card (full width, with inline filter)
#   - Labels card (full width)
#
# Spec/Network/Env/Labels render the pod JSON BYPASS — no curated
# field list, no rename. Whatever the PAT plane ships shows up here.
class Views::Pods::Show < Views::Base
  def initialize(current_path:, islands: [], current_island: nil, data: nil, updated_at: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @data           = data
    @updated_at     = updated_at
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, islands: @islands,
      current_island: @current_island, updated_at: @updated_at
    ) do
      if @current_island.nil?
        render Components::UI::NoIslandState.new
      elsif @data.error
        render Components::UI::ErrorState.new(error: @data.error)
      elsif @data.raw.nil?
        not_found
      else
        body
      end
    end
  end

  private

  def body
    div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
      render Components::Pods::Header.new(data: @data)
      stat_cards
      spec_network_grid
      render Components::Pods::EnvCard.new(pod: @data.raw)
      render Components::Pods::LabelsCard.new(pod: @data.raw)
    end
  end

  def not_found
    div(class: "mx-auto max-w-md py-16 flex flex-col items-center gap-3 text-center") do
      h2(class: "text-lg font-semibold text-voodu-text") { "Pod not found" }
      p(class: "text-voodu-text-2 text-sm") { "The container isn't reporting from this server right now." }
      a(href: "/pods", class: "text-voodu-accent-2 hover:underline text-sm") { "← back to pods" }
    end
  end

  def stat_cards
    div(
      class: "grid gap-3",
      style: "grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));"
    ) do
      @data.stat_cards.each do |card|
        render Components::Overview::StatCard.new(**card)
      end
    end
  end

  def spec_network_grid
    div(
      class: "grid gap-3 vmd:gap-4",
      style: "grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));"
    ) do
      render Components::Pods::SpecCard.new(pod: @data.raw)
      render Components::Pods::NetworkCard.new(pod: @data.raw)
    end
  end
end
