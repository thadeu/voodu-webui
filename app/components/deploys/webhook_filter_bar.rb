# frozen_string_literal: true

# The Webhooks filter bar, built from the same primitives as the Deployments
# one — and carrying the other form's state in hidden fields for the same
# reason: two forms that submit independently would each clear the other.
class Components::Deploys::WebhookFilterBar < Components::Base
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
      form_action: deploys_webhooks_path,
      frame: @frame,
      active_range: @data.range_key,
      ranges: WebhookReceiptsData::RANGES.keys + ["all"],
      from_iso: (@data.window&.first&.iso8601 if @data.custom_range?),
      until_iso: (@data.window&.last&.iso8601 if @data.custom_range?),
      extra_params: dropdown_state
    )
  end

  def dropdown_form
    form(
      action: deploys_webhooks_path, method: "get",
      class: "flex flex-wrap items-center gap-2",
      data: {
        controller: "auto-submit",
        # The COMMIT and not `change`: a menu that submits on every tick
        # reloads the frame under itself and disappears mid-pick.
        action: "ds-multiselect:commit->auto-submit#submit",
        turbo_frame: @frame,
        turbo_action: "advance"
      }
    ) do
      range_state.each { |name, value| input(type: "hidden", name: name, value: value) }

      # `status[]` with the brackets: a checkbox group under a scalar name
      # posts only the last box ticked.
      render Components::UI::Multiselect.new(
        name: "status[]", options: status_options, selected: @data.statuses,
        empty_label: "Any outcome", all_label: "All outcomes",
        group_label: "Outcome", clear_sentinel: true, trigger_class: trigger_class
      )

      render Components::UI::Multiselect.new(
        name: "reference[]", options: reference_options, selected: @data.references,
        empty_label: "Any repository", all_label: "All repositories",
        group_label: "Repository", clear_sentinel: true, trigger_class: trigger_class
      )

      search_input
      clear_button if @data.filtered?

      noscript { button(type: "submit", class: "text-[11.5px] text-voodu-link") { "Apply" } }
    end
  end

  # Labels, not machine names, and the count beside each — which is what makes
  # this filter answer a question on its own: "were any refused?" is visible
  # before you pick anything.
  def status_options
    Webhook::Receipt::STATUSES.map do |value, label|
      count = @data.status_counts[value]

      {value: value, label: count ? "#{label} (#{count})" : label}
    end
  end

  def reference_options
    @data.reference_options.map { |ref| {value: ref, label: ref} }
  end

  def search_input
    div(class: "relative flex-1 min-w-[160px]") do
      span(class: "absolute left-2 top-1/2 -translate-y-1/2 text-voodu-muted-2 pointer-events-none") do
        render Icon::MagnifyingGlassOutline.new(class: "w-3.5 h-3.5")
      end

      input(
        type: "search", name: "q", value: @data.query,
        placeholder: "delivery id, event, repo…", autocomplete: "off",
        class: "w-full pl-7 pr-2 #{Components::UI::TimeRangeFilter::CONTROL_H} text-[12px] bg-voodu-surface border border-voodu-border " \
               "text-voodu-text placeholder:text-voodu-muted-2 outline-none focus:border-voodu-accent",
        data: {
          controller: "search-filter",
          action: "input->search-filter#search keydown->search-filter#submitNow"
        }
      )
    end
  end

  def clear_button
    a(href: deploys_webhooks_path, data: {turbo_frame: @frame},
      title: "Clear filters", "aria-label": "Clear filters",
      class: "inline-flex items-center justify-center w-8 #{Components::UI::TimeRangeFilter::CONTROL_H} border border-voodu-border " \
             "bg-voodu-surface text-voodu-muted hover:text-voodu-text no-underline") do
      render Icon::XMarkOutline.new(class: "w-3.5 h-3.5")
    end
  end

  # Comma-joined under a SCALAR name: TimeRangeFilter emits one hidden input
  # per key with `value.to_s`, so an Array would ride along as a literal
  # `["failed"]`. The reading side splits on the comma.
  def dropdown_state
    out = {}
    out["status"] = @data.statuses.join(",") if @data.statuses.any?
    out["reference"] = @data.references.join(",") if @data.references.any?
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
