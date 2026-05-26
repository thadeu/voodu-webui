# frozen_string_literal: true

# Views::Metrics::DisplaySettings — "Settings" drawer body. Two
# responsibilities:
#
#   1. Toggle chart-card visibility (click a card to flip hidden mark)
#   2. Reorder chart cards via drag/drop (SortableJS)
#
# All cards live in ONE flat grid — resource + HTTP mixed. Each HTTP
# card carries an inline [http] badge so operators retain the visual
# cue. A single Update button commits both the hidden set + the
# current card order to sessionStorage and fires
# metrics-display:changed so the grid behind the drawer re-applies.
#
# Storage shape (sessionStorage, forward-compatible with SQLite JSONB):
#
#   {
#     "deployment": {
#       "hidden": ["net_rx_delta_bytes"],
#       "order":  ["cpu_percent", "req_count", "mem_usage_bytes", ...]
#     }
#   }
#
# `order` contains only the metrics the operator has explicitly placed.
# Cards for metrics not in `order` (e.g. a metric added in a later
# release) render at the end in default server order — so new metrics
# are visible by default and added cleanly to the operator's view.
class Views::Metrics::DisplaySettings < Views::Base
  def initialize(kind:, resource_specs:, http_specs:)
    @kind  = kind
    @specs = resource_specs + http_specs
  end

  def view_template
    return if @specs.empty?

    div(
      class: "p-4 flex flex-col gap-4",
      data: {
        controller:                          "metrics-display-settings",
        metrics_display_settings_kind_value: @kind
      }
    ) do
      header_row
      hint_row
      cards_grid
    end
  end

  private

  # header_row — "Charts" label + horizontal rule + [Update] button.
  def header_row
    div(class: "flex items-center gap-2.5") do
      span(
        class: "text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted shrink-0"
      ) { "Charts" }

      span(class: "flex-1 h-px bg-voodu-border")

      button(
        type: "button",
        data: {
          action:                          "click->metrics-display-settings#save",
          metrics_display_settings_target: "updateBtn"
        },
        class: [
          "inline-flex items-center gap-1.5 px-3 h-7",
          "border border-voodu-border bg-voodu-surface",
          "text-voodu-text-2 text-[11.5px] font-medium",
          "hover:bg-voodu-surface-2 hover:text-voodu-text",
          "transition-colors shrink-0"
        ].join(" ")
      ) { "Update" }
    end
  end

  # hint_row — tiny inline instructions so operators don't have to
  # guess that the grip icon is draggable or that click toggles
  # visibility. Two-sentence ceiling — anything longer means we got
  # the affordances wrong.
  def hint_row
    p(class: "text-[11px] text-voodu-muted-2 leading-relaxed") do
      plain "Click to toggle visibility. Drag "
      span(class: "inline-flex align-middle text-voodu-muted-2 mx-0.5") do
        render Icon::Bars3Outline.new(class: "w-3 h-3 inline")
      end
      plain " to reorder. Press "
      span(class: "font-semibold text-voodu-text-2") { "Update" }
      plain " to apply."
    end
  end

  # cards_grid — 3-4 col flat grid with all cards. SortableJS hooks
  # into this element to handle drag/drop. The grip icon inside each
  # card serves as the SortableJS handle so click-to-toggle on the
  # card body doesn't accidentally start a drag.
  def cards_grid
    div(
      data: { metrics_display_settings_target: "grid" },
      class: "grid grid-cols-3 vmd:grid-cols-4 gap-2"
    ) do
      @specs.each { |spec| metric_card(spec) }
    end
  end

  # metric_card — compact toggle tile + drag grip. Click anywhere
  # outside the grip toggles hidden state; the grip is the
  # SortableJS handle so reorder doesn't conflict with toggle.
  #
  # Visual states (applied by JS):
  #   Visible — solid border, colored dot, full opacity, check icon
  #   Hidden  — dashed border, dimmed dot, opacity-40, no check icon
  def metric_card(spec)
    div(
      data: {
        metrics_display_settings_target: "card",
        metric:                          spec[:metric],
        section:                         spec[:section],
        action:                          "click->metrics-display-settings#toggle"
      },
      class: [
        "relative flex flex-col gap-1.5 p-2.5 cursor-pointer select-none",
        "border border-voodu-border bg-voodu-surface-2",
        "hover:bg-voodu-surface transition-colors"
      ].join(" ")
    ) do
      div(class: "flex items-center gap-1.5") do
        # Drag grip — also the SortableJS handle. The toggle action
        # in the JS controller checks event.target against this
        # role (data-role="drag-handle") and returns early when the
        # click lands inside the handle, so dragging never triggers
        # a hide/show toggle as a side-effect.
        span(
          data:  { role: "drag-handle" },
          class: "cursor-grab active:cursor-grabbing text-voodu-muted-2 hover:text-voodu-text shrink-0",
          title: "Drag to reorder"
        ) do
          render Icon::Bars3Outline.new(class: "w-3 h-3 pointer-events-none")
        end

        span(
          data:  { role: "dot" },
          class: "inline-block w-2 h-2 rounded-full shrink-0",
          style: "background: #{spec[:color]};"
        )

        span(
          data:  { role: "check" },
          class: "hidden ml-auto text-voodu-accent-2"
        ) do
          render Icon::CheckOutline.new(class: "w-3 h-3")
        end
      end

      div(class: "flex items-baseline gap-1.5") do
        span(
          class: "text-[11px] font-semibold font-voodu-mono text-voodu-text truncate leading-tight"
        ) { spec[:label] }

        if spec[:section] == "http"
          span(
            class: "text-[9px] font-voodu-mono text-voodu-muted-2 uppercase tracking-[0.05em] border border-voodu-border px-1 leading-[1.4]"
          ) { "http" }
        end
      end

      if spec[:unit].present?
        span(class: "text-[10px] font-voodu-mono text-voodu-muted-2") { spec[:unit] }
      end
    end
  end
end
