# frozen_string_literal: true

# The chrome both Deploys tabs share: breadcrumb, title, and the rail.
#
# One screen with two tabs rather than two screens, because the question that
# brings somebody here spans both: "did my push land" starts at a repository
# and ends at a deployment. Two entries in the main sidebar made that a
# navigation problem.
#
# Subclasses fill `content`. The shell owns everything above and to the left of
# it, so the two tabs cannot drift into having different headers.
class Views::Deploys::Shell < Views::Base
  def initialize(current_path:, servers: [], current_server: nil, data: nil, **)
    @current_path = current_path
    @servers = servers
    @current_server = current_server
    @data = data
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers,
      current_server: @current_server, breadcrumb: breadcrumb
    ) do
      div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4") do
        page_head

        if @current_server.nil?
          render Components::UI::NoServerState.new
        else
          # min-h so the rail's divider runs down the page rather than stopping
          # under its last icon. Without it the row is only as tall as its
          # tallest child, which on a short repository list is two rows.
          div(class: "flex flex-col vmd:flex-row gap-3 vmd:gap-4 items-stretch " \
                     "vmd:min-h-[calc(100vh-210px)]") do
            render Components::Deploys::Rail.new(active: tab)
            div(class: "flex-1 min-w-0") { content }
          end
        end
      end
    end
  end

  private

  # Subclasses override these three.
  def tab = :repositories

  def subtitle = nil

  def content = nil

  def breadcrumb
    [{label: "Deploys", href: deploys_repositories_path}, {label: tab.to_s.capitalize}]
  end

  # page_head, not `header` — that is a Phlex HTML tag method.
  def page_head
    div(class: "flex flex-col gap-1") do
      h1(class: "text-[17px] font-semibold text-voodu-text") { "Deploys" }
      p(class: "text-[12.5px] text-voodu-muted") { subtitle } if subtitle
    end
  end
end
