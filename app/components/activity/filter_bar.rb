# frozen_string_literal: true

# Components::Activity::FilterBar — one row: the time range, then Status and
# Action as multi-select dropdowns.
#
# It replaced three rows of toggle chips. Chips were shareable and needed no
# JavaScript, which is why they came first, but eleven of them stacked three
# deep took more vertical space than the table's first four rows — on a screen
# whose whole job is the table.
#
# TWO FORMS, not one, and that is forced rather than chosen: the range picker
# ships its own `<form>` (it has to, for the custom from/until popover), and a
# form cannot nest. So the dropdowns live in a second one and each carries the
# other's state as hidden inputs. `hidden_state` and `extra_params` below are
# the two halves of keeping them in sync — miss either and changing the range
# silently clears the filters.
class Components::Activity::FilterBar < Components::Base
  STATUS_LABELS = {
    ActivityAction::IN_FLIGHT => "Running",
    "succeeded" => "Succeeded",
    "failed" => "Failed",
    "partial" => "Partial",
    ActivityAction::UNKNOWN => "Unknown"
  }.freeze

  def initialize(data:, frame:)
    @data = data
    @frame = frame
  end

  def view_template
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2 vmd:gap-3") do
      range_picker
      dropdown_form
      scope_chip if @data.selected_scope
    end
  end

  private

  # The same picker Metrics and Alerts use, custom window included. Not a
  # variant of it: a third time picker with its own idea of what "7d" means is
  # how two screens start disagreeing about the same question.
  def range_picker
    render Components::UI::TimeRangeFilter.new(
      form_action: activity_path,
      frame: @frame,
      active_range: @data.range,
      ranges: @data.range_keys,
      from_iso: @data.from_iso,
      until_iso: @data.until_iso,
      extra_params: extra_params
    )
  end

  # extra_params — what the RANGE form must carry so picking a window keeps the
  # filters. Comma-joined because the picker renders one hidden input per pair;
  # ActivityPageData reads that and the repeated-key form the checkboxes send.
  def extra_params
    params = {}
    params["status"] = @data.selected_statuses.join(",") if @data.selected_statuses.any?
    params["act"] = @data.selected_actions.join(",") if @data.selected_actions.any?
    params["origin"] = @data.selected_origins.join(",") if @data.selected_origins.any?
    params["scope"] = @data.selected_scope if @data.selected_scope
    params["q"] = @data.query if @data.query
    params
  end

  # The mirror image: what the DROPDOWN form must carry so picking a status
  # keeps the window. A custom range is three params, not one.
  def hidden_state
    state = {"range" => @data.range}

    if @data.custom_range?
      state["from"] = @data.from_iso
      state["until"] = @data.until_iso
    end

    state["scope"] = @data.selected_scope if @data.selected_scope
    state["origin"] = @data.selected_origins.join(",") if @data.selected_origins.any?
    state.compact
  end

  def dropdown_form
    form(
      method: "get",
      action: activity_path,
      data: {
        controller: "auto-submit",
        # ds-multiselect:commit and NOT change: a menu that submits on every
        # tick reloads the frame under itself, so the operator picks one option
        # and the dropdown disappears. Committing on close applies the whole
        # set at once, which is what a multi-select is for.
        action: "ds-multiselect:commit->auto-submit#submit",
        turbo_frame: @frame,
        turbo_action: "advance"
      },
      class: "flex flex-wrap items-center gap-2"
    ) do
      hidden_state.each { |name, value| input(type: "hidden", name: name, value: value) }

      status_select
      action_select
      search_input

      # Right after the last dropdown, where the controls it clears are. Off in
      # a corner it reads as a page action rather than the end of this strip.
      clear_button if @data.filters_applied?

      # Works without JavaScript too — the menus commit on close only once the
      # bundle has landed.
      noscript { button(type: "submit", class: "text-[11.5px] text-voodu-link") { "Apply" } }
    end
  end

  # Free text over the whole recorded line — a resource name inside a batch, a
  # config key, an IP, the city. It lives in THIS form so it shares the hidden
  # state the dropdowns already carry; a third form would be a third copy of
  # the same six params to keep in sync.
  #
  # `flex-1` because it is the one control with no natural width, and a search
  # box you can only see eight characters of is a search box people stop using.
  def search_input
    div(class: "relative flex-1 min-w-[160px]") do
      span(class: "absolute left-2 top-1/2 -translate-y-1/2 text-voodu-muted-2 pointer-events-none") do
        render Icon::MagnifyingGlassOutline.new(class: "w-3.5 h-3.5")
      end

      input(
        type: "search",
        name: "q",
        value: @data.query,
        placeholder: "filter any word…",
        autocomplete: "off",
        class: "w-full pl-7 pr-2 h-[26px] text-[12px] bg-voodu-surface border border-voodu-border " \
               "text-voodu-text placeholder:text-voodu-muted-2 outline-none focus:border-voodu-accent",
        data: {
          controller: "search-filter",
          action: "input->search-filter#search keydown->search-filter#submitNow"
        }
      )
    end
  end

  # Icon only. The two dropdowns beside it are already 132px each; a third
  # labelled control would push the strip past the table's own left edge on a
  # laptop, and this one is a reset — recognisable without a word.
  def clear_button
    a(
      href: activity_path,
      class: "inline-flex items-center justify-center w-[26px] h-[26px] shrink-0 border " \
             "border-voodu-border bg-voodu-surface text-voodu-muted " \
             "hover:bg-voodu-surface-2 hover:text-voodu-text",
      title: "Clear filters",
      "aria-label": "Clear filters",
      data: {turbo_frame: @frame, turbo_action: "advance"}
    ) do
      render Icon::XMarkOutline.new(class: "w-3.5 h-3.5")
    end
  end

  # `all_label` defaults to `empty_label` on purpose: for a filter, nothing
  # checked and everything checked show the same rows, so the trigger has to
  # say the same thing. Anything else invites a hunt for a difference.
  def status_select
    render Components::UI::Multiselect.new(
      name: "status[]",
      options: ActivityPageData::STATUSES.map { |v| {value: v, label: STATUS_LABELS.fetch(v, v)} },
      selected: @data.selected_statuses,
      empty_label: "All statuses",
      group_label: "Status",
      trigger_class: trigger_class
    )
  end

  def action_select
    render Components::UI::Multiselect.new(
      name: "act[]",
      options: ActivityPageData::ACTIONS.map { |v| {value: v, label: v} },
      selected: @data.selected_actions,
      empty_label: "All actions",
      group_label: "Action",
      trigger_class: trigger_class
    )
  end

  # Sized to the range chips beside it so the row reads as one control strip,
  # not two components that happened to land together.
  def trigger_class
    "px-2.5 h-[26px] min-w-[132px] bg-voodu-surface border border-voodu-border text-voodu-text-2 " \
      "hover:bg-voodu-surface-2 hover:text-voodu-text outline-none focus:border-voodu-accent"
  end

  # Scope is set by clicking one on a row, so the bar only shows it and offers
  # the way back out.
  def scope_chip
    a(
      href: scope_clear_href,
      class: "inline-flex items-center gap-1.5 px-2 py-[3px] text-[11.5px] font-voodu-mono leading-snug " \
             "whitespace-nowrap border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2",
      title: "Clear the scope filter",
      data: {turbo_frame: @frame, turbo_action: "advance"}
    ) do
      span { @data.selected_scope }
      span(class: "text-[13px] leading-none") { "×" }
    end
  end

  # Drops `page` with the filter: page 4 of the old result set has nothing to
  # do with the new one, and landing on an empty page reads as "no results"
  # when there are plenty.
  def scope_clear_href
    activity_path(request.query_parameters.except("page", "before", "after", "scope"))
  end
end
