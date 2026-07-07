# frozen_string_literal: true

# Components::Metrics::RangePicker — time-range control for the metrics
# charts. The segmented preset pills (1m / 5m / 15m / 1h / 6h / 24h / 7d)
# stay visually identical to before; a trailing "Custom" chip opens a
# From/Until popover (mirrors the Logs Analytics filter) so an operator
# can pin an ABSOLUTE past window instead of a rolling "last N". Custom
# is the focus — the presets are shortcuts that seed the custom dates.
#
# Mechanics: ONE GET form driven by the shared `time-range-filter`
# Stimulus controller (preset↔custom highlight, local→UTC normalisation
# on submit). Presets are now buttons (they requestSubmit the form)
# instead of <a> links, but carry the same segmented chrome. The form
# targets `_top` with turbo_action advance: the whole page re-renders so
# BOTH the subtitle ("last 1h" → the custom window) and the chart frame
# reflect the new window — the same full-navigation outcome the old <a>
# pills gave, minus the hard reload.
class Components::Metrics::RangePicker < Components::Base
  RANGES = %w[1m 5m 15m 1h 6h 24h 7d].freeze

  CHIP_ACTIVE = "border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2"
  CHIP_INACTIVE = "border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2 hover:text-voodu-text"

  # @param range       [String] active preset key (ignored when custom)
  # @param custom       [Boolean] an explicit from/until window is in play
  # @param from_iso/until_iso [String] resolved UTC window (custom round-trip)
  # @param extra_params [Hash] query params carried on every submit
  #   (scope_kind/scope_id/pid/interval) — MUST exclude range/from/until.
  # @param base_path    [String] where the GET form submits. Defaults to
  #   metrics_path (the grid). The expand modal passes metrics_chart_path.
  # @param turbo_stream [Boolean] modal mode: submit as a turbo-stream so the
  #   response swaps #chart-modal-body in place. Default false = the grid's
  #   full-page `_top` advance. Same knob as IntervalPicker — one range control
  #   serves both surfaces so the modal has the custom chip too.
  def initialize(range:, custom: false, from_iso: nil, until_iso: nil, extra_params: {}, base_path: nil, turbo_stream: false)
    @range = range.to_s
    @custom = custom
    @from_iso = from_iso
    @until_iso = until_iso
    @extra_params = extra_params
    @base_path = base_path
    @turbo_stream = turbo_stream
  end

  def view_template
    form(
      method: "get",
      action: @base_path || metrics_path,
      data: {
        controller: "time-range-filter",
        time_range_filter_target: "form",
        time_range_filter_range_value: active_range,
        time_range_filter_from_value: @from_iso,
        time_range_filter_until_value: @until_iso,
        action: "submit->time-range-filter#normalizeDates",
        # Modal submits as a turbo-stream (swaps the modal body in place);
        # the grid advances the whole page in the top frame.
        **(@turbo_stream ? {turbo_stream: "true"} : {turbo_frame: "_top", turbo_action: "advance"})
      },
      class: "flex items-center gap-2"
    ) do
      input(type: "hidden", name: "range", value: active_range, data: {time_range_filter_target: "range"})

      @extra_params.each do |name, value|
        input(type: "hidden", name: name.to_s, value: value.to_s)
      end

      preset_group
      custom_chip
    end
  end

  private

  def active_range
    @custom ? "custom" : @range
  end

  # preset_group — the segmented pills, chrome-identical to the old link
  # group (joined border, mono, h-8). Buttons now so they submit the form
  # via the controller's selectRange.
  def preset_group
    div(
      role: "tablist",
      aria: {label: "Time range"},
      class: "inline-flex items-stretch border border-voodu-border bg-voodu-surface"
    ) do
      RANGES.each_with_index do |r, i|
        active = !@custom && r == @range

        button(
          type: "button",
          role: "tab",
          aria: {selected: active.to_s},
          data: {
            time_range_filter_target: "preset",
            range: r,
            action: "click->time-range-filter#selectRange"
          },
          class: tokens(
            "inline-flex items-center justify-center min-w-9 px-2.5 h-8 font-voodu-mono text-[11px] font-bold",
            i.positive? ? "border-l border-voodu-border" : nil,
            active ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text-2 hover:bg-voodu-surface-2"
          )
        ) { r }
      end
    end
  end

  # custom_chip — calendar button + popover (From/Until + Apply). Same
  # markup the Logs Analytics filter uses, wired to the same controller.
  # The label is JS-filled with the active window (local zone); "Custom"
  # is just the pre-JS placeholder.
  def custom_chip
    div(class: "relative", data: {controller: "dropdown"}) do
      button(
        type: "button",
        data: {
          time_range_filter_target: "preset",
          range: "custom",
          action: "click->dropdown#toggle click->time-range-filter#openCustom"
        },
        class: tokens(
          "inline-flex items-center gap-1.5 px-2.5 h-8 border text-[11px] font-medium transition-colors",
          @custom ? CHIP_ACTIVE : CHIP_INACTIVE
        )
      ) do
        render Icon::CalendarDaysOutline.new(class: "w-3.5 h-3.5 shrink-0")
        span(class: "hidden vmd:inline", data: {time_range_filter_target: "customLabel"}) { "Custom" }
        render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 opacity-70")
      end

      custom_popover
    end
  end

  def custom_popover
    div(
      hidden: true,
      data: {dropdown_target: "menu"},
      class: "absolute right-0 top-[calc(100%+4px)] z-40 w-[280px] max-w-[calc(100vw-24px)] " \
             "border border-voodu-border-2 bg-voodu-surface shadow-2xl p-3 flex flex-col gap-3 text-left"
    ) do
      span(class: "text-[10px] uppercase tracking-[0.06em] text-voodu-muted") { "Custom range" }
      labeled_datetime("From", "from")
      labeled_datetime("Until", "until")
      button(
        type: "button",
        data: {action: "click->time-range-filter#applyCustom click->dropdown#close"},
        class: "inline-flex items-center justify-center gap-1.5 px-3 h-8 border border-voodu-accent-line " \
               "bg-voodu-accent-dim text-voodu-accent-2 text-[12px] font-medium hover:bg-voodu-accent/20 transition-colors"
      ) do
        render Icon::CheckOutline.new(class: "w-3.5 h-3.5")
        span { "Apply range" }
      end
    end
  end

  # labeled_datetime — visible datetime-local (display/edit only, no
  # `name`) paired with a hidden companion carrying the UTC value. The
  # controller fills the visible field from the resolved window in the
  # browser's local zone and writes UTC into the hidden field on submit;
  # assigning a "…Z" string to a datetime-local makes the browser blank it.
  def labeled_datetime(label, field)
    div(class: "flex flex-col gap-1 min-w-0") do
      span(class: "text-[10px] uppercase tracking-wide text-voodu-muted") { label }
      input(
        type: "datetime-local",
        data: {time_range_filter_target: "#{field}Input"},
        class: "h-8 px-2 border border-voodu-border bg-voodu-surface text-[12px] text-voodu-text " \
               "font-voodu-mono outline-none focus:border-voodu-accent-line"
      )
      input(type: "hidden", name: field, data: {time_range_filter_target: "#{field}Hidden"})
    end
  end
end
