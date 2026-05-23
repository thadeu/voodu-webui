# frozen_string_literal: true

# Components::Layouts::Dashboard — operational chrome every internal
# screen renders inside: fixed Sidebar, fixed Topbar, scrollable main
# content, plus a fixed ToastStack that picks up controller flashes.
#
# Usage from a Phlex view (always pass the trio):
#
#   class Views::Pods::Index < Views::Base
#     def view_template
#       render Components::Layouts::Dashboard.new(
#         current_path: @current_path,
#         islands:      @islands,
#         current_island: @current_island
#       ) do
#         # ...content...
#       end
#     end
#   end
class Components::Layouts::Dashboard < Components::Base
  def initialize(current_path: "/", islands: [], current_island: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
  end

  def view_template(&)
    div(class: "flex h-screen w-screen overflow-hidden bg-voodu-bg text-voodu-text") do
      render Components::Layouts::Sidebar.new(
        current_path: @current_path,
        islands: @islands,
        current_island: @current_island
      )
      div(class: "flex flex-1 flex-col overflow-hidden") do
        render Components::Layouts::Topbar.new(
          current_island: @current_island,
          islands: @islands
        )
        main(class: "flex-1 overflow-auto") { yield }
      end
    end

    # Flashes — outside the flex chain so position: fixed lands at
    # the viewport corner instead of inside .overflow-hidden.
    render Components::UI::ToastStack.new(flash: helpers.flash)
  end
end
