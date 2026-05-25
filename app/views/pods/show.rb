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
  # drawer: true → embedded render path used by Components::UI::Drawer.
  # Skips the Dashboard chrome (sidebar/topbar) so the drawer's body
  # gets just the pod detail surface, and tells Pods::Header to drop
  # its "All pods" back link (the drawer's own close X covers that).
  def initialize(current_path:, islands: [], current_island: nil, data: nil, updated_at: nil, drawer: false)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @data           = data
    @updated_at     = updated_at
    @drawer         = drawer
  end

  def view_template
    if @drawer
      drawer_body
    else
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
  end

  private

  # drawer_body — render-path used when the view is loaded into a
  # right-side Drawer (Metrics page peek).
  #
  # Differs from `body` (full page) in two ways:
  #   1. NO `stat_cards` — the operator opened the drawer from the
  #      Metrics page; the same CPU/Mem/Net charts are right behind
  #      it. Re-rendering them in the drawer would just duplicate
  #      noise + steal scroll real estate from Spec/Env/Labels.
  #   2. `drawer: true` on the Header → suppresses the back-link AND
  #      the "View logs" button (the Metrics page already exposes a
  #      separate Logs drawer trigger; same logs would mean two open
  #      paths to the same place).
  def drawer_body
    if @data.nil? || @data.raw.nil?
      div(class: "p-6 text-voodu-muted text-[12px]") { "Pod data unavailable." }
      return
    end

    div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
      render Components::Pods::Header.new(data: @data, drawer: true)
      spec_network_grid
      render Components::Pods::EnvCard.new(pod: @data.raw)
      render Components::Pods::LabelsCard.new(pod: @data.raw)
    end
  end

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
      a(href: pods_path, class: "text-voodu-accent-2 hover:underline text-sm") { "← back to pods" }
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
