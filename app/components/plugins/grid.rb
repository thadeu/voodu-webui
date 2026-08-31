# frozen_string_literal: true

# The cards, or the reason there are none.
#
# Extracted from the view because it renders in two places: inside the page on
# a full navigation, and alone inside the polling frame. Keeping it one
# component is what stops the two from drifting into slightly different empty
# states.
class Components::Plugins::Grid < Components::Base
  def initialize(data:)
    @data = data
  end

  def view_template
    return no_server if @data.nil?
    return unsupported if @data.unsupported?
    return unreachable unless @data.reachable?
    # `listing`, not `plugins`: with a catalogue, "nothing installed" is no
    # longer the end of the story — there are cards to show. Checking the
    # installed list here short-circuited straight past every one of them.
    return empty_state if @data.listing.empty?

    div(class: "flex flex-col gap-3") do
      toolbar
      pagination
      cards
      pagination
    end
  end

  private

  # No items-start: the row stretches, and every card is h-full, so a row of
  # cards lines up top and bottom. That only works because the description is
  # a bounded band — see Card#description.
  # Counts on the left, sort on the right. The counts are the useful half: the
  # list mixes what this server has with what it could have, and "4 installed"
  # answers the question the page is actually about.
  def toolbar
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2 vmd:gap-3") do
      span(class: "text-[12px] text-voodu-muted") do
        span(class: "font-voodu-mono text-voodu-text-2") { @data.installed_count.to_s }
        plain " installed"

        if @data.available_count.positive?
          plain " · "
          span(class: "font-voodu-mono text-voodu-text-2") { @data.available_count.to_s }
          plain " available"
        end
      end

      div(class: "hidden vmd:block flex-1")
      sort_control
    end
  end

  # A plain form, not JS. It submits on change, and it degrades to a visible
  # button for anyone without it — a select that only works with Stimulus is a
  # select that silently does nothing when the bundle fails to load.
  def sort_control
    form(action: plugins_path, method: "get", class: "flex items-center gap-2",
      data: {controller: "auto-submit", turbo_frame: PluginsController::FRAME}) do
      label(class: "text-[12px] text-voodu-muted", for: "plugins-sort") { "Sort" }

      select(
        id: "plugins-sort", name: "sort",
        data: {action: "change->auto-submit#submit"},
        class: "h-8 px-2 bg-voodu-surface border border-voodu-border text-voodu-text-2 " \
               "text-[12px] outline-none focus:border-voodu-accent"
      ) do
        PluginsData::SORTS.each do |value, text|
          option(value: value, selected: @data.sort == value) { text }
        end
      end

      # Visible only when the Stimulus controller has not taken over, so the
      # control works before the bundle lands and for anyone without it.
      noscript do
        button(
          type: "submit",
          class: "h-8 px-2.5 border border-voodu-border bg-voodu-surface text-voodu-text-2 text-[12px]"
        ) { "Apply" }
      end
    end
  end

  def cards
    div(class: "grid grid-cols-1 vmd:grid-cols-2 vlg:grid-cols-3 gap-3") do
      @data.page_of_plugins.each do |plugin|
        render Components::Plugins::Card.new(
          plugin: plugin, server: current_server, manageable: allowed?(:manage_servers)
        )
      end
    end
  end

  # Above and below, because a grid of 25 cards is taller than a screen and
  # scrolling back up to page is the kind of small tax that makes people stop
  # paging at all. Renders nothing on a single page — the component decides.
  #
  # The href keeps every other query parameter. Losing what you were looking at
  # by clicking "next" is the classic pagination bug, and it comes from
  # building the URL out of the page number alone.
  def pagination
    render Components::UI::Pagination.new(
      page: @data.page,
      total_pages: @data.total_pages,
      total: @data.total,
      per_page: @data.per_page,
      label: "plugins",
      frame: PluginsController::FRAME,
      href: ->(page) { plugins_path(request.query_parameters.merge(page: page)) }
    )
  end

  def no_server
    notice("Select a server to manage its plugins.")
  end

  # An unreachable box is NOT an empty list. Rendering "no plugins installed"
  # here would state a fact we do not have — the operator would go looking for
  # plugins that are on the box, wondering where they went.
  def unreachable
    div(class: "border border-voodu-amber/40 bg-voodu-amber-dim px-3.5 py-3 flex flex-col gap-1") do
      span(class: "text-[13px] font-medium text-voodu-amber") { "Could not reach this server" }
      span(class: "text-[12.5px] text-voodu-text-2") { @data.error.to_s }
      span(class: "text-[12px] text-voodu-muted") do
        plain "Its plugins are unaffected — this page just cannot list them right now."
      end
    end
  end

  # A 404 is not an outage. This controller simply does not have the plugin
  # endpoints yet, and the fix is a version rather than a network — saying
  # "could not reach" here would send the operator to look at the wrong thing.
  def unsupported
    div(class: "border border-voodu-border bg-voodu-surface px-3.5 py-3 flex flex-col gap-1") do
      span(class: "text-[13px] font-medium text-voodu-text") { "This server is running an older controller" }
      span(class: "text-[12.5px] text-voodu-text-2") do
        plain "Managing plugins from here needs a controller that exposes them over the PAT plane. "
        plain "Upgrade #{current_server&.name} and this page fills itself in."
      end
      span(class: "text-[12px] text-voodu-muted font-voodu-mono") do
        plain "until then: vd plugins:list on the box"
      end
    end
  end

  # Only reachable when the catalogue is empty too, which today means the
  # server answered and every known plugin is already on it.
  def empty_state
    notice("Nothing to show — this server already has every plugin we know about.")
  end

  def notice(message)
    div(class: "border border-voodu-border bg-voodu-surface px-3.5 py-6 text-center") do
      p(class: "m-0 text-[12.5px] text-voodu-muted") { message }
    end
  end
end
