# frozen_string_literal: true

# Components::UI::TimeRangeFilter — reusable preset + custom date/hour
# range picker, extracted from the logs-analytics filter so any
# surface gets the same timezone-correct behaviour. A GET form that
# targets a Turbo Frame with `turbo_action: advance`: each pick swaps
# just that frame AND pushes a bookmarkable URL. The
# `time-range-filter` Stimulus controller wires the preset chips, the
# custom popover, and the local→UTC normalisation on submit.
#
#   form_action  — where the GET goes (e.g. alerts_path)
#   frame        — Turbo Frame id to scope the re-query to
#   active_range — current range key, or "custom"
#   ranges       — ordered preset keys, e.g. %w[24h 7d 30d]
#   from_iso/until_iso — resolved UTC window (for the custom round-trip)
#   range_param/from_param/until_param — query param names
#   extra_params — hidden fields carried on every submit (e.g. tab:)
class Components::UI::TimeRangeFilter < Components::Base
  CHIP_ACTIVE   = "border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2"
  CHIP_INACTIVE = "border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2 hover:text-voodu-text"

  def initialize(form_action:, frame:, active_range:, ranges:, from_iso: nil, until_iso: nil,
                 range_param: "range", from_param: "from", until_param: "until", extra_params: {})
    @form_action  = form_action
    @frame        = frame
    @active_range = active_range.to_s
    @ranges       = ranges
    @from_iso     = from_iso
    @until_iso    = until_iso
    @range_param  = range_param
    @from_param   = from_param
    @until_param  = until_param
    @extra_params = extra_params
  end

  def view_template
    form(
      method: "get",
      action: @form_action,
      data: {
        controller:                  "time-range-filter",
        time_range_filter_target:    "form",
        time_range_filter_range_value: @active_range,
        time_range_filter_from_value:  @from_iso,
        time_range_filter_until_value: @until_iso,
        turbo_frame:  @frame,
        turbo_action: "advance",
        action:       "submit->time-range-filter#normalizeDates"
      },
      class: "flex flex-wrap items-center gap-1.5"
    ) do
      input(type: "hidden", name: @range_param, value: @active_range,
            data: { time_range_filter_target: "range" })

      @extra_params.each do |name, value|
        input(type: "hidden", name: name.to_s, value: value.to_s)
      end

      @ranges.each { |key| preset_chip(key) }
      custom_chip
    end
  end

  private

  def preset_chip(key)
    active = @active_range == key.to_s

    button(
      type: "button",
      data: {
        time_range_filter_target: "preset",
        range:  key,
        action: "click->time-range-filter#selectRange"
      },
      class: tokens(
        "inline-flex items-center px-2.5 h-7 border text-[11.5px] font-medium transition-colors",
        active ? CHIP_ACTIVE : CHIP_INACTIVE
      )
    ) { key.to_s }
  end

  def custom_chip
    div(class: "relative", data: { controller: "dropdown" }) do
      button(
        type: "button",
        data: {
          time_range_filter_target: "preset",
          range:  "custom",
          action: "click->dropdown#toggle click->time-range-filter#openCustom"
        },
        class: tokens(
          "inline-flex items-center gap-1.5 px-2.5 h-7 border text-[11.5px] font-medium transition-colors",
          @active_range == "custom" ? CHIP_ACTIVE : CHIP_INACTIVE
        )
      ) do
        render Icon::CalendarDaysOutline.new(class: "w-3 h-3 shrink-0")
        span(data: { time_range_filter_target: "customLabel" }) { "Custom" }
        render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 opacity-70")
      end

      custom_popover
    end
  end

  def custom_popover
    div(
      hidden: true,
      data:  { dropdown_target: "menu" },
      class: "absolute right-0 top-[calc(100%+4px)] z-40 w-[280px] max-w-[calc(100vw-24px)] border border-voodu-border-2 bg-voodu-surface shadow-2xl p-3 flex flex-col gap-3 text-left"
    ) do
      span(class: "text-[10px] uppercase tracking-[0.06em] text-voodu-muted") { "Custom range" }
      labeled_datetime("From",  @from_param)
      labeled_datetime("Until", @until_param)
      button(
        type: "button",
        data: { action: "click->time-range-filter#applyCustom click->dropdown#close" },
        class: "inline-flex items-center justify-center gap-1.5 px-3 h-8 border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 text-[12px] font-medium hover:bg-voodu-accent/20 transition-colors"
      ) do
        render Icon::CheckOutline.new(class: "w-3.5 h-3.5")
        span { "Apply range" }
      end
    end
  end

  # Visible datetime-local (display/edit only, no `name`) paired with a
  # hidden companion that carries the UTC value. The controller fills
  # the visible field from the resolved window in the browser's local
  # zone, and writes UTC into the hidden field on submit — assigning a
  # "…Z" string to a datetime-local makes the browser blank it.
  def labeled_datetime(label, field)
    target = field == @from_param ? "from" : "until"

    div(class: "flex flex-col gap-1 min-w-0") do
      span(class: "text-[10px] uppercase tracking-wide text-voodu-muted") { label }
      input(
        type: "datetime-local",
        data: { time_range_filter_target: "#{target}Input" },
        class: "h-8 px-2 border border-voodu-border bg-voodu-surface text-[12px] text-voodu-text font-voodu-mono outline-none focus:border-voodu-accent-line"
      )
      input(type: "hidden", name: field, data: { time_range_filter_target: "#{target}Hidden" })
    end
  end
end
