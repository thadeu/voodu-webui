# frozen_string_literal: true

# Views::Metrics::DisplaySettings — "Settings" drawer body.
#
# Two card kinds in the flat grid:
#
#   - SINGLE tiles: one metric, click toggles hidden
#   - GROUP tiles:  "Latency" + "Errors" with a count badge
#                   ("2 of 3"). Clicking opens a floating popover
#                   (position: fixed, wider than the card) with the
#                   sub-metric checkboxes. The popover has its own
#                   SortableJS instance so operators can reorder
#                   percentiles within the group too.
#
# Card heights are uniform — the popover is OUT of the card's box
# (fixed positioning), so expanding a group doesn't stretch its
# grid row mates.
#
# Storage shape (flat individual metric keys in hidden + order):
#
#   {
#     "deployment": {
#       "hidden": ["latency_p90_ms", "req_3xx", ...],
#       "order":  ["cpu_percent", "latency_p95_ms", ...],
#       "cols":   2
#     }
#   }
class Views::Metrics::DisplaySettings < Views::Base
  def initialize(kind:, items:)
    @kind  = kind
    @items = items
  end

  def view_template
    return if @items.empty?

    # @container — registers this div as a container-query context
    # so the cards grid (and any future responsive bits inside) can
    # respond to DRAWER width, not viewport width. The drawer is
    # resizable (30vw default, operator-tunable), so viewport
    # breakpoints like `vmd:` would lie about how much room is
    # actually available for cards.
    div(
      class: "p-4 flex flex-col gap-4 @container",
      data: {
        controller:                          "metrics-display-settings",
        metrics_display_settings_kind_value: @kind
      }
    ) do
      header_row
      hint_row
      columns_picker
      cards_grid
    end
  end

  private

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

  def columns_picker
    div(class: "flex items-center gap-2.5") do
      span(class: "text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted shrink-0") { "Columns" }

      span(class: "text-[10px] text-voodu-muted-2") { "(applies when 3+ visible)" }

      div(
        data: { metrics_display_settings_target: "colsPicker" },
        class: "ml-auto inline-flex items-center gap-1"
      ) do
        [2, 3, 4].each { |n| cols_pill(n) }
      end
    end
  end

  def cols_pill(n)
    button(
      type: "button",
      data: {
        action:                          "click->metrics-display-settings#selectCols",
        cols:                            n.to_s,
        metrics_display_settings_target: "colsBtn"
      },
      class: [
        "inline-flex items-center justify-center w-8 h-7",
        "border border-voodu-border bg-voodu-surface",
        "text-voodu-text-2 text-[11.5px] font-voodu-mono font-medium",
        "hover:bg-voodu-surface-2 hover:text-voodu-text",
        "transition-colors"
      ].join(" ")
    ) { n.to_s }
  end

  # cards_grid — container-query-responsive grid. Cols scale with
  # DRAWER width (not viewport):
  #
  #   default (≤384px drawer) → 2 cols    (narrow drawer, default 30vw)
  #   @sm (≥384px container)  → 3 cols
  #   @md (≥448px container)  → 4 cols    (operator resized wider)
  #
  # SortableJS handles drag/drop via the grip on each tile. Group
  # popovers are position:fixed so opening them doesn't disturb the
  # grid layout regardless of how many cols are active.
  def cards_grid
    div(
      data: { metrics_display_settings_target: "grid" },
      class: "grid grid-cols-2 @sm:grid-cols-3 @md:grid-cols-4 gap-2"
    ) do
      @items.each do |item|
        if item[:kind] == :group
          group_card(item)
        else
          single_card(item)
        end
      end
    end
  end

  # single_card — one metric tile. Three rows of compact content
  # gives the same vertical footprint as the group tile.
  def single_card(spec)
    div(
      data: {
        metrics_display_settings_target: "card",
        card_type:                       "single",
        metric:                          spec[:metric],
        section:                         spec[:section],
        default_visible:                 spec[:default_visible] == false ? "false" : "true",
        action:                          "click->metrics-display-settings#toggle"
      },
      class: card_base_classes
    ) do
      card_header_row(spec[:color])
      card_label_row(spec[:label], spec[:section])

      if spec[:unit].present?
        span(class: "text-[10px] font-voodu-mono text-voodu-muted-2 leading-tight") { spec[:unit] }
      else
        span(class: "text-[10px] leading-tight invisible") { "·" } # height placeholder
      end
    end
  end

  # group_card — picker tile. Same compact footprint as a single
  # card. The popover with sub-metric checkboxes lives below in
  # the SAME element but is position:fixed when opened (so it
  # floats over the grid, wider than the card itself).
  def group_card(item)
    sub_metrics_csv = item[:members].map { |m| m[:metric] }.join(",")

    div(
      data: {
        metrics_display_settings_target: "card",
        card_type:                       "group",
        group_key:                       item[:group_key],
        sub_metrics:                     sub_metrics_csv,
        section:                         item[:section],
        expanded:                        "false",
        action:                          "click->metrics-display-settings#toggle"
      },
      class: card_base_classes
    ) do
      card_header_row(item[:color], with_chevron: true)
      card_label_row(item[:label], item[:section])

      span(class: "text-[10px] font-voodu-mono text-voodu-muted-2 leading-tight") do
        span(data: { role: "count" }) { "0 of #{item[:members].size}" }
        if item[:unit].present?
          plain " · #{item[:unit]}"
        end
      end

      # Popover with sub-metric checkboxes. Hidden via Tailwind's
      # `hidden` class (not the HTML attribute — `display: flex/block`
      # utilities defeat it across cascade layers).
      #
      # Positioning: position: absolute relative to the CARD (which
      # has position: relative from card_base_classes). The card's
      # ancestor drawer has a CSS transform for slide animation,
      # which would break position: fixed (transformed ancestors
      # become the containing block for fixed children, so
      # `left: X` becomes "X from the drawer" instead of "X from
      # viewport"). Absolute positioning relative to the card
      # sidesteps that entirely.
      #
      # Anchoring: JS centers the popover horizontally on the card,
      # clamps so it stays inside the drawer's edges. The arrow at
      # the top of the popover stays aligned with the card's center
      # even when the panel was clamped — gives the operator a
      # clear "this popover came from THIS card" visual cue.
      div(
        data: { role: "group-panel", group_panel_sub_metrics: sub_metrics_csv },
        class: tokens(
          "hidden",
          "absolute top-full mt-2 z-50",
          "border border-voodu-border-2 bg-voodu-surface-2 shadow-2xl",
          "p-2 space-y-0.5",
          "min-w-[220px]"
        )
      ) do
        # Arrow connector — small rotated square positioned at the
        # top edge of the popover, JS aligns its `left` to the
        # card's center within the panel. Two visible borders
        # (top + left) match the panel border, so it reads as a
        # continuous "speech-bubble" pointer back to the card.
        div(
          data: { role: "group-arrow" },
          class: tokens(
            "absolute -top-[5px] w-2.5 h-2.5 rotate-45",
            "border-t border-l border-voodu-border-2 bg-voodu-surface-2"
          )
        )

        item[:members].each { |m| sub_metric_row(m) }
      end
    end
  end

  # sub_metric_row — checkbox + grip + colored dot + label. Each
  # row is draggable inside the panel (its own SortableJS instance),
  # letting operators reorder percentiles within a group.
  def sub_metric_row(spec)
    div(
      data: {
        role:            "sub-metric",
        metric:          spec[:metric],
        default_visible: spec[:default_visible] == false ? "false" : "true",
        action:          "click->metrics-display-settings#toggleSubMetric"
      },
      class: "flex items-center gap-2 px-1.5 py-1.5 cursor-pointer hover:bg-voodu-surface"
    ) do
      span(
        data:  { role: "sub-handle" },
        class: "cursor-grab active:cursor-grabbing text-voodu-muted-2 hover:text-voodu-text shrink-0",
        title: "Drag to reorder"
      ) do
        render Icon::Bars3Outline.new(class: "w-3 h-3 pointer-events-none")
      end

      span(
        data: { role: "checkbox" },
        class: "inline-flex items-center justify-center w-3.5 h-3.5 border border-voodu-border shrink-0"
      ) do
        span(
          data: { role: "check-icon" },
          class: "hidden text-voodu-accent-2"
        ) do
          render Icon::CheckOutline.new(class: "w-2.5 h-2.5")
        end
      end

      span(
        class: "inline-block w-2 h-2 rounded-full shrink-0",
        style: "background: #{spec[:color]};"
      )

      span(class: "text-[11.5px] font-voodu-mono text-voodu-text-2 truncate flex-1") { spec[:label] }
    end
  end

  # card_header_row — top strip shared by single + group tiles:
  # grip icon, colored dot, and chevron OR check tick.
  def card_header_row(color, with_chevron: false)
    div(class: "flex items-center gap-1.5") do
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
        style: "background: #{color};"
      )

      if with_chevron
        span(
          data:  { role: "chevron" },
          class: "ml-auto text-voodu-muted-2 transition-transform"
        ) do
          render Icon::ChevronDownOutline.new(class: "w-3 h-3")
        end
      else
        span(
          data:  { role: "check" },
          class: "hidden ml-auto text-voodu-accent-2"
        ) do
          render Icon::CheckOutline.new(class: "w-3 h-3")
        end
      end
    end
  end

  def card_label_row(label, section)
    div(class: "flex items-baseline gap-1.5") do
      span(
        class: "text-[11px] font-semibold font-voodu-mono text-voodu-text truncate leading-tight"
      ) { label }

      if section == "http"
        span(class: "text-[9px] font-voodu-mono text-voodu-muted-2 uppercase tracking-[0.05em] border border-voodu-border px-1 leading-[1.4]") { "http" }
      end
    end
  end

  def card_base_classes
    [
      "relative flex flex-col gap-1.5 p-2.5 cursor-pointer select-none",
      "border border-voodu-border bg-voodu-surface-2",
      "hover:bg-voodu-surface transition-colors"
    ].join(" ")
  end
end
