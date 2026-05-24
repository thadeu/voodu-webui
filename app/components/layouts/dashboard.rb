# frozen_string_literal: true

# Components::Layouts::Dashboard — operational chrome.
#
# Layout topology:
#
#   Desktop (md+):
#     ┌─────────┬───────────────────────┐
#     │ Sidebar │ Topbar                │
#     │ 220px   ├───────────────────────┤
#     │  (in    │ <main scroll>          │
#     │  flow)  │                       │
#     └─────────┴───────────────────────┘
#
#   Mobile (< md):
#     Sidebar slides in over a backdrop, triggered by the hamburger
#     in the topbar. When closed it lives at translate-x-(-100%) so
#     it's off-canvas. The Topbar/main fill the whole viewport.
#
# The entire layout is wrapped in `data-controller="mobile-nav"` so
# the sidebar + backdrop + hamburger button all hang off one
# coordinated controller (see mobile_nav_controller.js).
class Components::Layouts::Dashboard < Components::Base
  def initialize(current_path: "/", islands: [], current_island: nil, updated_at: nil, uptime: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @updated_at     = updated_at
    @uptime         = uptime
  end

  def view_template
    div(
      class: "flex h-screen w-screen overflow-hidden bg-voodu-bg text-voodu-text",
      data: { controller: "mobile-nav" }
    ) do
      render Components::Layouts::Sidebar.new(
        current_path: @current_path,
        islands: @islands,
        current_island: @current_island
      )
      mobile_backdrop
      div(class: "flex flex-1 flex-col overflow-hidden min-w-0") do
        render Components::Layouts::Topbar.new(
          current_island: @current_island,
          islands: @islands,
          updated_at: @updated_at,
          uptime: @uptime
        )
        main(class: "flex-1 overflow-auto") { yield }
      end
    end

    render Components::UI::ToastStack.new(flash: helpers.flash)
  end

  private

  # Backdrop sits behind the sidebar but above main content. Hidden
  # by default; the mobile-nav controller toggles `hidden` when the
  # drawer opens. Click closes the drawer. Forced hidden on vd-md+
  # so the desktop layout never paints it.
  def mobile_backdrop
    div(
      class: "hidden fixed inset-0 z-40 bg-black/55 backdrop-blur-sm vmd:!hidden",
      data: {
        mobile_nav_target: "backdrop",
        action: "click->mobile-nav#close"
      },
      aria: { hidden: "true" }
    )
  end
end
