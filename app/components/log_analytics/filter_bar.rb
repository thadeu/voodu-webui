# frozen_string_literal: true

# Components::LogAnalytics::FilterBar — the query form. A GET form that
# targets the results Turbo Frame with `turbo_action: advance`, so each
# query swaps just the table AND pushes a bookmarkable URL
# (/logs/analytics?range=1h&q=…). The log-analytics Stimulus controller
# wires the preset chips, the custom-range toggle, the local→UTC date
# normalization on submit, and the filter panel open/close.
#
# Layout: only the time-range presets are visible here. The pod scope + the
# QUERY editor live in the ScopeGate panel in the results body (opened by the
# funnel in the results toolbar); this form carries the applied choice as
# hidden fields (#scope_fields), OUTSIDE the results frame, so it survives the
# frame swap on every run.
class Components::LogAnalytics::FilterBar < Components::Base
  # Pre-paint class sets for the preset chips. Both listed here (not
  # built in JS) so Tailwind's source scanner keeps both variants in the
  # bundle — the controller swaps between them on click.
  CHIP_ACTIVE = "border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2"
  CHIP_INACTIVE = "border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2 hover:text-voodu-text"

  def initialize(data:)
    @data = data
  end

  def view_template
    form(
      method: "get",
      action: logs_analytics_path,
      data: {
        log_analytics_target: "form",
        turbo_frame: Components::LogAnalytics::Results::FRAME_ID,
        turbo_action: "advance",
        action: "submit->log-analytics#normalizeDates"
      },
      class: "contents"
    ) do
      input(type: "hidden", name: "range", value: @data.range, data: {log_analytics_target: "range"})

      scope_fields

      # The page header row doubles as the filter's top bar: "Logs" + the
      # Analytics/Follow tabs on the left, the time-range presets pushed right
      # via the Header's actions slot (justify-between). Rendering it INSIDE the
      # form is what keeps the custom-range hidden from/until fields submitting.
      render Components::Logs::Header.new(active: :analytics).with_actions { preset_group }
    end
  end

  private

  # scope_fields — the APPLIED pod scope + query, as hidden fields. The editing
  # UI is the ScopeGate panel inside the results frame (re-rendered per query);
  # this form lives outside the frame, so it is what Refresh / range chips
  # re-submit. log-analytics#applyScope rewrites these on every Apply.
  # "All pods" is an explicit scope=all — an empty pods[] means "not chosen".
  def scope_fields
    input(type: "hidden", name: "q", value: @data.search, data: {log_analytics_target: "query"})

    div(hidden: true, data: {log_analytics_target: "scopeFields"}) do
      input(type: "hidden", name: "scope", value: "all") if @data.scope_all? && @data.pods.empty?
      @data.pods.each { |pod| input(type: "hidden", name: "pods[]", value: pod) }
    end
  end

  # preset_group — time-range presets + the custom-range chip. Sits in the
  # header's actions slot (right side); wraps below the title on a narrow
  # viewport (the Header row is flex-wrap).
  def preset_group
    div(class: "flex flex-wrap items-center gap-1.5 vmd:justify-end") do
      LogSearchData::RANGES.each_key { |key| preset_chip(key, key) }
      custom_chip
    end
  end

  def preset_chip(value, label)
    active = @data.range == value

    button(
      type: "button",
      data: {
        log_analytics_target: "preset",
        range: value,
        action: "click->log-analytics#selectRange"
      },
      class: tokens(
        "inline-flex items-center px-2.5 h-7 border text-[11.5px] font-medium transition-colors",
        active ? CHIP_ACTIVE : CHIP_INACTIVE
      )
    ) { label }
  end

  # custom_chip — the date-range button: it ALWAYS reflects the active
  # window as "<from> – <until>" (the controller fills it on connect and
  # whenever a preset is picked — presets are just shortcuts that feed
  # this button). Clicking opens the popover to fine-tune; Apply commits
  # an explicit custom window. Still a `preset` target (data-range=
  # "custom") so it highlights when the active selection is a manual
  # range. "Custom" is only the pre-JS placeholder.
  def custom_chip
    div(class: "relative", data: {controller: "dropdown"}) do
      button(
        type: "button",
        data: {
          log_analytics_target: "preset",
          range: "custom",
          action: "click->dropdown#toggle click->log-analytics#openCustom"
        },
        class: tokens(
          "inline-flex items-center gap-1.5 px-2.5 h-7 border text-[11.5px] font-medium transition-colors",
          @data.custom? ? CHIP_ACTIVE : CHIP_INACTIVE
        )
      ) do
        render Icon::CalendarDaysOutline.new(class: "w-3 h-3 shrink-0")
        span(data: {log_analytics_target: "customLabel"}) { "Custom" }
        render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 opacity-70")
      end

      custom_popover
    end
  end

  # custom_popover — the From/Until pickers, anchored under the chip.
  # Each datetime-local is display-only (no name); a hidden companion
  # carries the UTC value (see labeled_datetime). Apply re-runs the query.
  def custom_popover
    div(
      hidden: true,
      data: {dropdown_target: "menu"},
      class: "absolute left-0 top-[calc(100%+4px)] z-40 w-[280px] max-w-[calc(100vw-24px)] border border-voodu-border-2 bg-voodu-surface shadow-2xl p-3 flex flex-col gap-3 text-left"
    ) do
      span(class: "text-[10px] uppercase tracking-[0.06em] text-voodu-muted") { "Custom range" }
      labeled_datetime("From", "from")
      labeled_datetime("Until", "until")
      button(
        type: "button",
        data: {action: "click->log-analytics#applyCustom click->dropdown#close"},
        class: "inline-flex items-center justify-center gap-1.5 px-3 h-8 border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 text-[12px] font-medium hover:bg-voodu-accent/20 transition-colors"
      ) do
        render Icon::CheckOutline.new(class: "w-3.5 h-3.5")
        span { "Apply range" }
      end
    end
  end

  # labeled_datetime — a VISIBLE datetime-local (display/edit only, no
  # `name`) paired with a HIDDEN companion that actually carries the
  # value to the server. Why split them:
  #   - The visible value is NOT server-rendered: the log-analytics
  #     controller fills it from the resolved UTC window converted to the
  #     browser's local zone (timezone-correct round-trip).
  #   - On submit the controller writes the UTC ISO into the HIDDEN field,
  #     never into the datetime-local — assigning a "…Z" string to a
  #     datetime-local input makes the browser silently blank it (it only
  #     accepts a local value with no timezone), which previously wiped
  #     the visible window after the first Run and reverted the query.
  def labeled_datetime(label, field)
    div(class: "flex flex-col gap-1 min-w-0") do
      span(class: "text-[10px] uppercase tracking-wide text-voodu-muted") { label }
      input(
        type: "datetime-local",
        data: {log_analytics_target: "#{field}Input"},
        class: "h-8 px-2 border border-voodu-border bg-voodu-surface text-[12px] text-voodu-text font-voodu-mono outline-none focus:border-voodu-accent-line"
      )
      input(type: "hidden", name: field, data: {log_analytics_target: "#{field}Hidden"})
    end
  end
end
