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
        else
          framed_body
        end
      end
    end
  end

  private

  # framed_body — wraps the page body in a Turbo Frame so the
  # state-tick broadcast from StateSyncIslandJob can refresh it
  # without a manual reload. Same pattern as Dashboard + Pods::Index:
  # no `src=` on the frame (the JS handler sets it to
  # `window.location.href` right before reload(), preserving the
  # current URL).
  #
  # `target="_top"` — every link inside the frame (Restart confirm
  # modal, View logs drawer trigger, View metrics anchor, the back
  # link to /pods) must navigate the whole page, not get trapped by
  # Turbo's frame navigation. Without it, "View metrics" would request
  # /metrics with a Turbo-Frame header, find no matching frame, and
  # render "Content missing".
  #
  # We wrap the error / not_found branches too so a transient "pod
  # not in warehouse yet" state recovers automatically on the next
  # sync — operator doesn't have to manually refresh after a pod
  # creation.
  def framed_body
    # `refresh="morph"` — when StateSyncIslandJob's state_tick triggers
    # frame.reload(), Turbo 8 uses Idiomorph to diff the response
    # against the current DOM instead of replacing the frame body
    # wholesale. Two big wins:
    #
    #   1. `[data-turbo-permanent]` nodes (the Drawer + Confirmable
    #      roots) are skipped during morph → open drawers/modals keep
    #      their client-side state (data-open, Stimulus instance vars
    #      like log_stream_controller's `wrap` flag, scroll position
    #      inside the logs viewer, fetched body content).
    #   2. The stat cards, status pills, and other live fields are
    #      morphed in place rather than re-created → no flash, no
    #      controller disconnect/connect cycles on unchanged nodes.
    #
    # Without morph, plain Turbo Frame reload replaces the entire
    # frame body. Even `[data-turbo-permanent]` is ignored (that
    # attribute is a Turbo Drive feature, not Turbo Frames).
    turbo_frame_tag(
      "island-#{@current_island.id}-state",
      target:  "_top",
      refresh: "morph",
      data:    { state_frame: true }
    ) do
      if @data.error
        render Components::UI::ErrorState.new(error: @data.error)
      elsif @data.raw.nil?
        not_found
      else
        body
      end
    end
  end

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
      stale_banner if @data.stale?
      render Components::Pods::Header.new(data: @data)
      stat_cards
      spec_network_grid
      render Components::Pods::EnvCard.new(pod: @data.raw)
      render Components::Pods::LabelsCard.new(pod: @data.raw)
    end
  end

  # stale_banner — mirrors the Overview + /pods banners. Surfaces
  # the "controller offline — showing last-known state" hint at the
  # top of the pod show page too, so the Header's pill flipping to
  # Offline + the stat cards going flat are explained by ONE
  # explicit reason instead of leaving the operator to guess.
  def stale_banner
    age = @data.updated_at ? "#{time_ago_in_words(@data.updated_at)} ago" : "moments ago"

    div(class: "px-3 py-2 border border-voodu-amber/40 bg-voodu-amber-dim text-voodu-amber text-[12.5px] flex items-center gap-2") do
      render Icon::ExclamationTriangleOutline.new(class: "w-3.5 h-3.5")
      span { "Controller offline — showing last-known state from " }
      span(class: "font-voodu-mono opacity-80") { age }
      span { ". Pod status is uncertain until the agent comes back." }
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
      # `stale: @data.stale?` so the SPEC card's state.status row
      # flips to Offline alongside the header pill — otherwise the
      # operator sees "● Offline" up top but "state.status ● Running"
      # right below it on the same page. Single source of truth for
      # "is this pod's status trustworthy right now?" lives on @data.
      render Components::Pods::SpecCard.new(pod: @data.raw, stale: @data.stale?)
      render Components::Pods::NetworkCard.new(pod: @data.raw)
    end
  end
end
