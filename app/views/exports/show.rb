# frozen_string_literal: true

# Views::Exports::Show — standalone page for one export's status.
#
# Two render paths:
#
#   - Drawer embed mode (`drawer_controller.js` fetches the URL on
#     first open or after form submit): chrome-less body that
#     slots into the panel. The status block + subscription
#     handle live updates from there.
#
#   - Full page (operator middle-clicked / hit the URL directly):
#     wrapped in the Dashboard layout so they get sidebar + topbar
#     context. The same status block renders inside.
#
# Either way the body is `Components::Logs::ExportStatus`, which
# subscribes to the export's Turbo Stream channel.
class Views::Exports::Show < Views::Base
  # embed: passed by the controller (resolved from ?embed=1 or
  # X-Drawer-Embed header). Phlex views don't get `params`/`request`
  # for free, so the controller is the single decision point.
  def initialize(current_path:, islands: [], current_island: nil,
                 updated_at: nil, export: nil, embed: false)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @updated_at     = updated_at
    @export         = export
    @embed          = embed
  end

  def view_template
    # Embed mode = the request came from the Drawer's lazy fetch.
    # Render just the status block; no Dashboard chrome.
    if @embed
      render Components::Logs::ExportStatus.new(export: @export)
    else
      render Components::Layouts::Dashboard.new(
        current_path: @current_path, islands: @islands,
        current_island: @current_island, updated_at: @updated_at
      ) do
        div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
          h1(class: "text-[22px] font-semibold text-voodu-text tracking-tight") do
            plain "Log export ##{@export.id}"
          end
          render Components::Logs::ExportStatus.new(export: @export)
        end
      end
    end
  end
end
