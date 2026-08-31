# frozen_string_literal: true

# The plugins screen for one server — a marketplace rather than a list.
#
# What it replaces was a read-only table buried in Settings: you could see what
# was installed and nothing else, so installing anything meant SSH'ing to the
# box and running `vd plugins:install`. The point of this screen is that the
# box is the only thing that needs to know about plugins, and the operator
# should not have to be on it.
class Views::Plugins::Index < Views::Base
  # Slow on purpose. An install takes as long as a clone plus hooks, so a tight
  # poll would be a lot of requests to watch nothing change; five seconds is
  # brisk enough that "installing…" resolving feels immediate.
  POLL_MS = 5000

  def initialize(current_path:, servers: [], current_server: nil, data: nil, **)
    @current_path = current_path
    @servers = servers
    @current_server = current_server
    @data = data
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers,
      current_server: @current_server, breadcrumb: [{label: "Plugins"}]
    ) do
      div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
        page_head
        install_form if manageable?
        grid_frame
      end
    end
  end

  private

  # page_head, not `header` — that is a Phlex HTML tag method.
  def page_head
    div(class: "flex flex-col gap-1") do
      h1(class: "text-[17px] font-semibold text-voodu-text") { "Plugins" }
      p(class: "text-[12.5px] text-voodu-muted") do
        plain "What this server can do beyond the core — installed, updated and removed from here."
      end
    end
  end

  # The install field takes what an operator would type after
  # `vd plugins:install`, because that is the string they already have in front
  # of them: a repository, a git URL, or a path on the box.
  def install_form
    render Components::UI::SectionCard.new(title: "Install a plugin") do
      form(action: install_plugin_path, method: "post",
        class: "flex flex-col vmd:flex-row vmd:items-start gap-2 p-3.5") do
        input(type: "hidden", name: "authenticity_token", value: form_authenticity_token)

        div(class: "flex-1 min-w-0 flex flex-col gap-1.5") do
          input(
            type: "text", name: "source", required: true,
            placeholder: "thadeu/voodu-redis",
            autocomplete: "off", spellcheck: "false",
            "aria-label": "Plugin repository or path",
            class: "w-full px-3 h-9 bg-voodu-surface-2 border border-voodu-border text-voodu-text " \
                   "font-voodu-mono text-[12.5px] outline-none placeholder:text-voodu-muted-2 " \
                   "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line"
          )
          span(class: "text-[11.5px] text-voodu-muted") do
            plain "A GitHub repo (owner/name), a git URL, or a directory on the server."
          end
        end

        div(class: "flex flex-col gap-1.5 vmd:w-40") do
          input(
            type: "text", name: "version",
            placeholder: "version (optional)",
            autocomplete: "off", spellcheck: "false",
            "aria-label": "Version tag",
            class: "w-full px-3 h-9 bg-voodu-surface-2 border border-voodu-border text-voodu-text " \
                   "font-voodu-mono text-[12.5px] outline-none placeholder:text-voodu-muted-2 " \
                   "focus:border-voodu-accent focus:ring-1 focus:ring-voodu-accent-line"
          )
          span(class: "text-[11.5px] text-voodu-muted") { "Blank takes the latest." }
        end

        render Components::UI::Button.new(
          tag: :button, type: "submit", variant: :primary, size: :sm,
          class: "h-9 shrink-0"
        ) do
          render Icon::SquaresPlusOutline.new(class: "w-3.5 h-3.5")
          span { "Install" }
        end
      end
    end
  end

  # The grid polls; the form above does not, so a tick never swaps out a
  # half-typed repository name.
  #
  # The src carries the CURRENT page. Without it every tick refetches page one
  # and the operator on page two is silently dragged back — five seconds after
  # they clicked, which reads as the page having a mind of its own rather than
  # as a bug with a cause.
  def grid_frame
    div(data: {controller: "polling", polling_interval_value: POLL_MS}) do
      turbo_frame_tag(PluginsController::FRAME, src: frame_src) do
        render Components::Plugins::Grid.new(data: @data)
      end
    end
  end

  # Carries BOTH the page and the sort. A tick that dropped either would
  # silently move the grid under the operator five seconds after they set it —
  # which reads as the page having a mind of its own, not as a bug.
  def frame_src
    params = {}
    params[:page] = @data.page if @data && @data.page > 1
    params[:sort] = @data.sort if @data && @data.sort != PluginsData::DEFAULT_SORT

    params.empty? ? plugins_path : plugins_path(params)
  end

  def manageable? = allowed?(:manage_servers)
end
