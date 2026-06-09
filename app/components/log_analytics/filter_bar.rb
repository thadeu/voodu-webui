# frozen_string_literal: true

# Components::LogAnalytics::FilterBar — the query form. A GET form that
# targets the results Turbo Frame with `turbo_action: advance`, so each
# query swaps just the table AND pushes a bookmarkable URL
# (/logs/analytics?range=1h&q=callid). The log-analytics Stimulus
# controller wires the preset chips, the custom-range toggle, and the
# local→UTC date normalisation on submit.
#
# Layout stacks on mobile (presets on their own wrapping row; search +
# regex + scope + Run below), side-by-side from vmd: up.
class Components::LogAnalytics::FilterBar < Components::Base
  # Pre-paint class sets for the preset chips. Both listed here (not
  # built in JS) so Tailwind's source scanner keeps both variants in the
  # bundle — the controller swaps between them on click.
  CHIP_ACTIVE   = "border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2"
  CHIP_INACTIVE = "border-voodu-border bg-voodu-surface text-voodu-text-2 hover:bg-voodu-surface-2 hover:text-voodu-text"

  def initialize(data:, pods: [])
    @data = data
    @pods = Array(pods)
  end

  def view_template
    form(
      method: "get",
      action: logs_analytics_path,
      data: {
        log_analytics_target: "form",
        turbo_frame:  Components::LogAnalytics::Results::FRAME_ID,
        turbo_action: "advance",
        action:       "submit->log-analytics#normalizeDates"
      },
      class: "flex flex-col gap-2.5"
    ) do
      input(type: "hidden", name: "range", value: @data.range, data: { log_analytics_target: "range" })

      main_row
    end
  end

  private

  # main_row — the header: query controls + Run on the left, the
  # time-range presets pushed to the far right. Stacks on mobile (search
  # full width, then regex / pods / Run, then the presets wrap below).
  def main_row
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2.5") do
      query_group
      div(class: "hidden vmd:block vmd:flex-1")
      preset_group
    end
  end

  # query_group — search + regex + pod scope + Run, left-aligned.
  def query_group
    div(class: "flex flex-col vmd:flex-row vmd:items-center gap-2 min-w-0") do
      search_input
      div(class: "flex items-center gap-2") do
        regex_toggle
        pod_scope
        run_button
      end
    end
  end

  # preset_group — time-range chips, right-aligned in the header row.
  # The fixed presets submit on click; Custom is a dropdown whose
  # popover holds the From/Until pickers (see custom_chip).
  def preset_group
    div(class: "flex flex-wrap items-center gap-1.5 vmd:justify-end shrink-0") do
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
        range:  value,
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
    div(class: "relative", data: { controller: "dropdown" }) do
      button(
        type: "button",
        data: {
          log_analytics_target: "preset",
          range:  "custom",
          action: "click->dropdown#toggle click->log-analytics#openCustom"
        },
        class: tokens(
          "inline-flex items-center gap-1.5 px-2.5 h-7 border text-[11.5px] font-medium transition-colors",
          @data.custom? ? CHIP_ACTIVE : CHIP_INACTIVE
        )
      ) do
        render Icon::CalendarDaysOutline.new(class: "w-3 h-3 shrink-0")
        span(data: { log_analytics_target: "customLabel" }) { "Custom" }
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
      data:  { dropdown_target: "menu" },
      class: "absolute right-0 top-[calc(100%+4px)] z-40 w-[280px] max-w-[calc(100vw-24px)] border border-voodu-border-2 bg-voodu-surface shadow-2xl p-3 flex flex-col gap-3 text-left"
    ) do
      span(class: "text-[10px] uppercase tracking-[0.06em] text-voodu-muted") { "Custom range" }
      labeled_datetime("From",  "from")
      labeled_datetime("Until", "until")
      button(
        type: "button",
        data: { action: "click->log-analytics#applyCustom click->dropdown#close" },
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
        data: { log_analytics_target: "#{field}Input" },
        class: "h-8 px-2 border border-voodu-border bg-voodu-surface text-[12px] text-voodu-text font-voodu-mono outline-none focus:border-voodu-accent-line"
      )
      input(type: "hidden", name: field, data: { log_analytics_target: "#{field}Hidden" })
    end
  end

  def search_input
    div(class: "flex items-center gap-2 px-2.5 h-8 border border-voodu-border bg-voodu-surface w-full vmd:w-[300px] text-voodu-muted") do
      render Icon::MagnifyingGlassOutline.new(class: "w-3.5 h-3.5 shrink-0")
      input(
        type: "search",
        name: "q",
        value: @data.search,
        placeholder: "filter by callid, path, status, message…",
        class: "flex-1 min-w-0 bg-transparent border-0 outline-none text-[12px] text-voodu-text placeholder:text-voodu-muted-2 h-full"
      )
    end
  end

  def regex_toggle
    label(class: "inline-flex items-center gap-1.5 px-2 h-8 border border-voodu-border bg-voodu-surface text-[11.5px] text-voodu-text-2 cursor-pointer select-none whitespace-nowrap") do
      input(
        type: "checkbox",
        name: "regex",
        value: "1",
        checked: @data.regex?,
        class: "w-3.5 h-3.5 accent-voodu-accent"
      )
      span(class: "font-voodu-mono") { ".*" }
      span(class: "hidden vmd:inline") { "regex" }
    end
  end

  # pod_scope — multi-select pod scope via the design-system dropdown.
  def pod_scope
    render Components::LogAnalytics::PodScopePicker.new(pods: @pods, selected: @data.pods)
  end

  def run_button
    button(
      type: "submit",
      class: "inline-flex items-center justify-center gap-1.5 px-4 h-8 border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 text-[12px] font-medium hover:bg-voodu-accent/20 transition-colors"
    ) do
      render Icon::PlayOutline.new(class: "w-3.5 h-3.5")
      span { "Run" }
    end
  end

end
