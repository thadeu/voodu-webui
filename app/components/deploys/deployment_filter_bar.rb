# frozen_string_literal: true

# The Deployments filter bar — the same shape Activity's has, built from the
# same primitives.
#
# TWO FORMS, and each carries the other's state in hidden fields. The range
# picker and the dropdowns submit independently, and a form that posted only
# its own fields would silently clear everything set by the other — pick a
# status, change the range, lose the status.
class Components::Deploys::DeploymentFilterBar < Components::Base
  def initialize(data:, frame:)
    @data = data
    @frame = frame
  end

  def view_template
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2 vmd:gap-3") do
      range_picker
      dropdown_form
    end
  end

  private

  def range_picker
    render Components::UI::TimeRangeFilter.new(
      form_action: deploys_deployments_path,
      frame: @frame,
      active_range: @data.range_key,
      ranges: DeploymentsData::RANGES.keys + ["all"],
      from_iso: (@data.window&.first&.iso8601 if @data.custom_range?),
      until_iso: (@data.window&.last&.iso8601 if @data.custom_range?),
      extra_params: dropdown_state
    )
  end

  # One form for the dropdowns and the search box, so a change to either
  # submits both — and so the "clear" button beside them can empty the lot.
  def dropdown_form
    form(
      action: deploys_deployments_path, method: "get",
      class: "flex flex-wrap items-center gap-2",
      data: {
        controller: "auto-submit",
        # `ds-multiselect:commit` and NOT `change`. Two reasons, and the form
        # did nothing at all without this line: the controller needs an event
        # bound to it, and the event has to be the COMMIT — a menu that submits
        # on every tick reloads the frame under itself, so the operator picks
        # one option and the dropdown vanishes. Committing on close applies the
        # whole set at once, which is what a multi-select is for.
        action: "ds-multiselect:commit->auto-submit#submit",
        turbo_frame: @frame,
        # The URL follows the filters, so a filtered view is a link somebody
        # can send and the back button returns to the previous one.
        turbo_action: "advance"
      }
    ) do
      range_state.each { |name, value| input(type: "hidden", name: name, value: value) }

      # `status[]`, with the brackets. A checkbox GROUP posting under a scalar
      # name sends only the last box ticked — the dropdown would look like it
      # applied and would quietly filter by one value.
      render Components::UI::Multiselect.new(
        name: "status[]", options: status_options, selected: @data.statuses,
        empty_label: "Any status", all_label: "All statuses",
        group_label: "Status", clear_sentinel: true, trigger_class: trigger_class
      )

      render Components::UI::Multiselect.new(
        name: "repo[]", options: repo_options, selected: @data.repos_filter,
        empty_label: "Any repository", all_label: "All repositories",
        group_label: "Repository", clear_sentinel: true, trigger_class: trigger_class
      )

      search_input
      clear_button if @data.filtered?

      # Works without JavaScript too — the menus commit on close only once the
      # bundle has landed.
      noscript { button(type: "submit", class: "text-[11.5px] text-voodu-link") { "Apply" } }
    end
  end

  def status_options
    DeploymentsData::STATUSES.map do |status|
      count = @data.status_counts[status]

      {value: status, label: count ? "#{status} (#{count})" : status}
    end
  end

  def repo_options
    @data.repo_options.map { |repo| {value: repo, label: repo} }
  end

  # The controller and its actions live on the INPUT, matching Activity —
  # `search-filter` debounces on `input` and submits immediately on Enter. My
  # first version put the controller on the wrapper and named an action that
  # does not exist (`#submit` instead of `#search`), so typing did nothing.
  def search_input
    div(class: "relative flex-1 min-w-[160px]") do
      span(class: "absolute left-2 top-1/2 -translate-y-1/2 text-voodu-muted-2 pointer-events-none") do
        render Icon::MagnifyingGlassOutline.new(class: "w-3.5 h-3.5")
      end

      input(
        type: "search", name: "q", value: @data.query,
        placeholder: "commit, sha, error…", autocomplete: "off",
        class: "w-full pl-7 pr-2 #{Components::UI::TimeRangeFilter::CONTROL_H} text-[12px] bg-voodu-surface border border-voodu-border " \
               "text-voodu-text placeholder:text-voodu-muted-2 outline-none focus:border-voodu-accent",
        data: {
          controller: "search-filter",
          action: "input->search-filter#search keydown->search-filter#submitNow"
        }
      )
    end
  end

  # An icon button after the last dropdown, matching Activity. It links rather
  # than submits: "no filters" is a URL, and a submit would have to post empty
  # values for every field to mean the same thing.
  def clear_button
    a(href: deploys_deployments_path, data: {turbo_frame: @frame},
      title: "Clear filters", "aria-label": "Clear filters",
      class: "inline-flex items-center justify-center w-8 #{Components::UI::TimeRangeFilter::CONTROL_H} border border-voodu-border " \
             "bg-voodu-surface text-voodu-muted hover:text-voodu-text no-underline") do
      render Icon::XMarkOutline.new(class: "w-3.5 h-3.5")
    end
  end

  # What the OTHER form must carry so submitting it does not drop this one's
  # state. See the class comment.
  #
  # COMMA-JOINED UNDER A SCALAR NAME, matching Activity. TimeRangeFilter emits
  # one hidden input per key with `value.to_s`, so handing it an Array would
  # render `value="[\"failed\"]"` — a filter that survives a range change as a
  # literal Ruby inspect string. The reading side splits on the comma; see
  # DeploymentsData#multi, which accepts both spellings for exactly this.
  def dropdown_state
    out = {}
    out["status"] = @data.statuses.join(",") if @data.statuses.any?
    out["repo"] = @data.repos_filter.join(",") if @data.repos_filter.any?
    out["q"] = @data.query if @data.query.present?

    out
  end

  # Every control in the strip at one height — see
  # TimeRangeFilter::CONTROL_H for why that constant lives there.
  def trigger_class
    "px-2.5 #{Components::UI::TimeRangeFilter::CONTROL_H} min-w-[132px] bg-voodu-surface " \
      "border border-voodu-border text-voodu-text-2 hover:bg-voodu-surface-2 " \
      "hover:text-voodu-text outline-none focus:border-voodu-accent"
  end

  def range_state
    out = {"range" => @data.range_key}

    if @data.custom_range?
      out["from"] = @data.window&.first&.iso8601
      out["until"] = @data.window&.last&.iso8601
    end

    out.compact
  end
end
