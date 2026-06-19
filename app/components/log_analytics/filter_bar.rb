# frozen_string_literal: true

# Components::LogAnalytics::FilterBar — the query form. A GET form that
# targets the results Turbo Frame with `turbo_action: advance`, so each
# query swaps just the table AND pushes a bookmarkable URL
# (/logs/analytics?range=1h&q=…). The log-analytics Stimulus controller
# wires the preset chips, the custom-range toggle, the local→UTC date
# normalisation on submit, and the filter drawer open/close.
#
# Layout: only the time-range presets stay inline. The QUERY editor (the
# LogQuery DSL, syntax-highlighted) + the pod scope + Run live in a
# right-side slide-in drawer, opened by the funnel icon in the results
# toolbar (Components::LogAnalytics::Results#header_actions). The drawer
# panel is rendered HERE, inside the <form>, so the editor (name=q) and
# the pod checkboxes serialise with it — but OUTSIDE the results frame, so
# it survives the frame swap on every Run.
class Components::LogAnalytics::FilterBar < Components::Base
  # Pre-paint class sets for the preset chips. Both listed here (not
  # built in JS) so Tailwind's source scanner keeps both variants in the
  # bundle — the controller swaps between them on click.
  CHIP_ACTIVE = "border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2"
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
        turbo_frame: Components::LogAnalytics::Results::FRAME_ID,
        turbo_action: "advance",
        action: "submit->log-analytics#normalizeDates"
      },
      class: "contents"
    ) do
      input(type: "hidden", name: "range", value: @data.range, data: {log_analytics_target: "range"})

      # The page header row doubles as the filter's top bar: "Logs" + the
      # Analytics/Follow tabs on the left, the time-range presets pushed right
      # via the Header's actions slot (justify-between). Rendering it INSIDE the
      # form is what keeps the custom-range hidden from/until fields submitting.
      render Components::Logs::Header.new(active: :analytics).with_actions { preset_group }
      filter_panel
    end
  end

  private

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

  # ── filter drawer ──────────────────────────────────────────────────────────

  # filter_panel — right-side slide-in (reuses the Drawer slide CSS), holding
  # the query editor + pod scope + Run. `inert` + off-screen by default; the
  # log-analytics controller drops `inert` and sets `data-open` to slide it in.
  # No backdrop on purpose — the results stay visible/usable behind it so the
  # operator iterates on the query and watches the table update.
  def filter_panel
    aside(
      inert: true,
      role: "dialog",
      "aria-label": "Log filter",
      data: {log_analytics_target: "filterPanel"},
      class: tokens(
        "fixed top-0 right-0 h-screen z-[60] w-[min(560px,calc(100vw-24px))]",
        "flex flex-col bg-voodu-bg-2 border-l border-voodu-border",
        "shadow-[var(--voodu-shadow-drawer)]",
        "translate-x-full transition-transform duration-200 ease-out",
        "data-[open]:translate-x-0"
      )
    ) do
      resize_handle
      panel_header
      panel_body
      panel_footer
    end
  end

  # resize_handle — 6px grab strip on the LEFT edge (mirrors the DS Drawer).
  # pointerdown enters drag mode in the log-analytics controller; the width is
  # clamped + persisted there. Wider hit area than the visible 1px border.
  def resize_handle
    div(
      data: {action: "pointerdown->log-analytics#startFilterResize"},
      aria: {hidden: "true"},
      title: "Drag to resize",
      class: "absolute top-0 left-0 bottom-0 w-1.5 -ml-1 cursor-col-resize hover:bg-voodu-accent/30 active:bg-voodu-accent/60 z-[5] touch-none"
    )
  end

  def panel_header
    header(class: "flex items-center gap-2 px-4 h-14 border-b border-voodu-border bg-voodu-surface shrink-0") do
      render Icon::FunnelOutline.new(class: "w-4 h-4 text-voodu-accent-2 shrink-0")
      h2(class: "m-0 text-[13px] font-semibold text-voodu-text flex-1 min-w-0") { "Filter" }
      button(
        type: "button",
        title: "Close",
        "aria-label": "Close filter",
        data: {action: "click->log-analytics#closeFilter"},
        class: "inline-flex items-center justify-center w-7 h-7 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2 shrink-0"
      ) { render Icon::XMarkOutline.new(class: "w-3.5 h-3.5") }
    end
  end

  # panel_body — natural order: choose the pod(s) first, THEN write the query.
  def panel_body
    div(class: "flex-1 overflow-y-auto p-4 flex flex-col gap-4") do
      pod_section
      query_section
    end
  end

  # query_section — the shared LogQuery editor (syntax highlight + field
  # validation + cheatsheet). name=q so it serialises with this GET form; it's
  # the analytics surface, so Cmd+Enter runs the query (submits default true).
  def query_section
    render Components::UI::QueryEditor.new(
      value: @data.search,
      name: "q",
      label: "Query",
      placeholder: "filter @message like /timeout/",
      rows: "4"
    )
  end

  def pod_section
    div(class: "flex flex-col gap-2") do
      field_label("Pod scope")
      render Components::LogAnalytics::PodScopePicker.new(pods: @pods, selected: @data.pods)
    end
  end

  def panel_footer
    footer(class: "flex items-center justify-between gap-2 px-4 py-3 border-t border-voodu-border bg-voodu-surface shrink-0") do
      span(class: "text-[11px] text-voodu-muted") do
        plain "⌘/Ctrl + Enter to run"
      end
      run_button
    end
  end

  def run_button
    button(
      type: "submit",
      data: {role: "run-query"},
      class: "inline-flex items-center justify-center gap-1.5 px-4 h-8 border border-voodu-accent-line bg-voodu-accent-dim text-voodu-accent-2 text-[12px] font-medium hover:bg-voodu-accent/20 transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
    ) do
      render Icon::PlayOutline.new(class: "w-3.5 h-3.5")
      span { "Run" }
    end
  end

  def field_label(text)
    span(class: "text-[10px] font-semibold uppercase tracking-[0.06em] text-voodu-muted-2") { text }
  end
end
