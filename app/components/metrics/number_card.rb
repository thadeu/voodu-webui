# frozen_string_literal: true

# Components::Metrics::NumberCard — a single big-number tile for a dashboard
# log-count panel (scope_kind "log"). Where ChartCard plots a warehouse
# series, this shows ONE number: how many log lines matched the panel's
# LogQuery filter over the dashboard's range (see LogMetricData).
#
# Visual — deliberately spare ("just the number"):
#
#   ┌────────────────────────────┐
#   │ FS · INVITE           [1h] │   colored label + range chip
#   │                            │
#   │           1,284            │   big bold count, centered
#   │                            │
#   └────────────────────────────┘
#
# Lives in the SAME metrics-display grid as the chart cards: it carries
# data-metric-key (the panel_key) so the Settings/Order drawer hides,
# reorders and resizes it alongside the charts. Grid stretch makes it match
# the height of any chart card sharing its row, so the number centers nicely.
class Components::Metrics::NumberCard < Components::Base
  # @param label [String] panel label ("fs · INVITE")
  # @param color [String] accent color token for the label
  # @param formatted [String] count with thousands separators ("1,284")
  # @param range [String] dashboard range key, shown as a chip ("1h")
  # @param metric [String, nil] the panel_key → data-metric-key for hide/reorder
  # @param truncated [Boolean] count hit COUNT_CAP → render "≥ N"
  # @param clamped [Boolean] range outran log retention → note "last Nd"
  # @param series [Array] [{ts:, value:, formatted:}] for the trend sparkline.
  #   Empty (live-scan fallback before the warehouse fills) → no sparkline.
  # @param range_ms [Integer] range width for the sparkline x-axis math.
  # @param sub [String, nil] muted qualifier ("avg · duration_ms"); nil for a
  #   plain count.
  # @param default_visible [Boolean]
  def initialize(label:, color:, formatted:, range:, metric: nil,
    truncated: false, clamped: false, series: [], numbers: nil, range_ms: nil, sub: nil, default_visible: true)
    @label = label
    @color = color
    @formatted = formatted
    @range = range
    @metric = metric
    @truncated = truncated
    @clamped = clamped
    # series — SINGLE tile: a flat [{ts,value,formatted}] sparkline. MULTI tile
    # (numbers present): the multi-series array [{label,color,points}] the shared
    # timeline draws (one area per pod). numbers — MULTI only: one stat per pod
    # ({label, color, formatted, value}) rendered side by side.
    @series = Array(series)
    @numbers = numbers
    @range_ms = range_ms
    @sub = sub
    @default_visible = default_visible
  end

  # multi? — a multi-pod Number: N current-value stats side by side over a shared
  # multi-area timeline. @numbers carries the per-pod headlines.
  def multi? = @numbers.is_a?(Array) && @numbers.size >= 2

  def view_template
    root_data = {}

    if @metric
      root_data[:metrics_display_target] = "card"
      root_data[:metric_key] = @metric
    end

    root_data[:default_visible] = "false" unless @default_visible

    # number-card controller → live show/hide of the sparkline from the options
    # popover ("Show timeline" / "T"). Only wired when there IS a sparkline + a
    # panel key to broadcast on; a bare number tile needs neither.
    if @metric && chart?
      root_data[:controller] = "number-card"
      root_data[:number_card_key_value] = @metric
    end

    div(
      class: "relative bg-voodu-surface border border-voodu-border p-3.5 flex flex-col gap-2 min-w-0",
      data: root_data
    ) do
      card_header
      value_block
      timeline_block

      if @metric
        resize_handle("left")
        resize_handle("right")
      end
    end
  end

  private

  # Named card_header (not header) — `header` is a Phlex HTML tag method;
  # method_missing would shadow the tag and break rendering.
  def card_header
    div(class: "flex flex-col gap-0.5 min-w-0") do
      div(class: "flex items-start justify-between gap-2") do
        span(
          class: "text-[11.5px] font-semibold uppercase tracking-[0.05em] min-w-0 truncate",
          style: "color: #{@color};"
        ) { @label }

        div(class: "flex items-center gap-1 shrink-0") do
          span(
            class: "inline-flex items-center px-1.5 h-[18px] text-[10.5px] font-medium rounded-voodu-sm " \
                   "border border-voodu-border text-voodu-muted font-voodu-mono"
          ) { @range }

          options_menu if @metric && chart?
        end
      end

      # sub — the agg + field qualifier ("avg · duration_ms"). Mono because the
      # field is a JSON identifier; muted so it doesn't compete with the label.
      span(class: "text-[10px] font-voodu-mono text-voodu-muted-2 truncate") { @sub } if @sub.present?
    end
  end

  # value_block — the headline number, centered + grown (flex-1) so it absorbs
  # the card's extra height (vs the taller chart cards in the same row) and
  # lands mid-tile above the sparkline — no empty gap.
  def value_block
    return multi_value_block if multi?

    div(class: "flex-1 flex flex-col items-center justify-center gap-1.5 py-2") do
      div(class: "flex items-baseline gap-1") do
        span(class: "text-voodu-muted text-[22px] font-voodu-mono leading-none") { "≥" } if @truncated
        span(class: "font-voodu-mono #{value_size_classes} font-semibold leading-none text-voodu-text") { @formatted }
      end

      if @clamped
        span(class: "text-[10.5px] text-voodu-muted-2 text-center px-2") do
          "counted over last #{LogTail::FilePath::RETENTION_DAYS}d (log retention)"
        end
      end
    end
  end

  # multi_value_block — the multi-pod headline row: one CURRENT-value stat per pod
  # side by side, each colored to match its timeline line, with the pod name as a
  # caption below. The name truncates (+ tooltip) so a long "<server> · <pod>"
  # never breaks the row; the stats share the width evenly (flex-1 min-w-0).
  def multi_value_block
    div(class: "flex-1 flex items-center justify-around gap-2 py-2 min-w-0") do
      @numbers.each do |n|
        # container-type: inline-size → the no-timeline headline sizes to THIS
        # column's width (cqw), so it fills a wide wall-mounted TV card and
        # auto-shrinks as pods multiply / the card narrows.
        div(class: "flex flex-col items-center gap-1 min-w-0 flex-1", style: "container-type: inline-size;") do
          span(
            class: "font-voodu-mono #{multi_value_size} font-semibold leading-none truncate max-w-full",
            style: multi_value_style(n[:color])
          ) { n[:formatted] }

          span(
            class: "#{multi_caption_size} text-voodu-muted-2 truncate max-w-full",
            data: {tooltip: n[:label]}, "aria-label": n[:label]
          ) { n[:label] }
        end
      end
    end
  end

  # multi_value_size — the per-pod headline font WITH a timeline: a fixed
  # step-down by pod count (the chart owns the lower card, so the number stays
  # modest — smaller on narrow, larger at vmd+). WITHOUT a timeline the size is
  # container-relative instead (see multi_value_style), so this returns nothing.
  def multi_value_size
    return "" unless chart?

    case @numbers.size
    when 2 then "text-[30px] vmd:text-[40px]"
    when 3 then "text-[22px] vmd:text-[32px]"
    when 4 then "text-[18px] vmd:text-[26px]"
    else "text-[15px] vmd:text-[20px]"
    end
  end

  # multi_value_style — the headline's inline style: its series color, plus (when
  # there's no timeline) a container-query font size so the stat FILLS its column.
  # clamp keeps it readable on a narrow card and bounded on a huge TV; the middle
  # cqw term is the sweet spot — ~gauge-sized on a normal card, bigger as the card
  # widens. cqw resolves against the column (container-type set on the parent).
  def multi_value_style(color)
    base = "color: #{color};"
    return base if chart?

    "#{base} font-size: clamp(28px, 20cqw, 120px);"
  end

  # multi_caption_size — the pod-name caption. A hair bigger without a timeline so
  # it stays legible under the scaled-up stat (still a supporting line, not the
  # hero).
  def multi_caption_size
    chart? ? "text-[10px]" : "text-[13px] vmd:text-[15px]"
  end

  # chart? — whether this tile draws its timeline. SINGLE: ≥2 points. MULTI: any
  # pod series carries points. The operator can also turn it off per-panel
  # (show_chart false → empty series); then the tile is just the number(s).
  def chart?
    if multi?
      @series.is_a?(Array) && @series.any? { |s| Array(s[:points]).any? }
    else
      @series.size >= 2
    end
  end

  # value_size_classes — the headline number's font size. A number-only tile
  # (no chart) gives the count the entire card, so it scales up dramatically;
  # a tile that ALSO draws a chart keeps a modest size (the chart needs the
  # lower two-thirds). Long counts step down so a 7-figure number doesn't
  # overflow the tile width (mono digits are wide). Sized off @formatted's
  # length, which includes the thousands separators that take real space.
  def value_size_classes
    return "text-[40px] vmd:text-[44px]" if chart?

    case @formatted.to_s.length
    when 0..4 then "text-[72px] vmd:text-[88px]"
    when 5..7 then "text-[52px] vmd:text-[60px]"
    else "text-[40px] vmd:text-[44px]"
    end
  end

  # sparkline — the count's trend as a FULL area chart (axes + time X + value Y),
  # the SAME area+gradient style the metric charts (CPU/Memory) use, so a count
  # tile reads as "big number on top + a chart that matches its neighbours". The
  # headline number (flex-1, centered) absorbs the slack, so the tile matches a
  # neighbouring chart card's height with no gap.
  #
  # Height is 150 (vs the metric chart's 200): the big number + the "sum"
  # sub-line eat the top of the tile, so a shorter chart keeps the count card's
  # natural height ≤ the metric card's. That makes the metric card drive the
  # row height and the number centers in the remaining space — instead of the
  # count card being the tallest and forcing everything else taller. Needs ≥2
  # points; the densified (full-window zero-fill) series keeps the area filled
  # instead of collapsing to a bare line on mostly-zero counts.
  # timeline_block — wraps the sparkline in the number-card controller's toggle
  # target so the options popover ("Show timeline" / "T") can hide/reveal it live
  # without a reload. Only present when there's a chart to toggle.
  def timeline_block
    return unless chart?

    div(data: {number_card_target: "timeline"}) { sparkline }
  end

  # sparkline — the timeline under the headline(s). SINGLE: a flat area sparkline
  # of the one series. MULTI: the shared multi-AREA chart (one filled area per
  # pod, reusing the multi-line/area Chart) — WITH its interactive legend, so the
  # operator gets the same labels + click-to-hide/show + hover-highlight a real
  # chart has. key: @metric persists the hidden-line selection across refreshes.
  def sparkline
    if multi?
      render Components::Metrics::Chart.new(
        points: [], series: @series, color: @color, unit: "", label: @label,
        range_ms: @range_ms || (60 * 60 * 1000), height: 150, axes: true,
        style: :area, key: @metric
      )
    else
      render Components::Metrics::Chart.new(
        points: @series, color: @color, unit: "", label: @label,
        range_ms: @range_ms || (60 * 60 * 1000), height: 150, axes: true
      )
    end
  end

  # options_menu — the triple-dot popover (mirrors ChartCard's). Toggles:
  # "Show timeline" (T) — the sparkline under the headline; and, on a MULTI tile,
  # "Show dots" (D) — the per-pod markers on the multi-area timeline (a single
  # area sparkline has no dots, so that tile skips it). The menu portals out on
  # open, so it carries its own panel-options controller keyed by the panel id;
  # the toggles persist (sessionStorage) + broadcast to this card's number-card
  # controller (timeline) and the timeline chart's metrics-chart controller
  # (dots), both matched by the same key.
  def options_menu
    div(class: "relative", data: {controller: "popover"}) do
      button(
        type: "button",
        data: {popover_target: "trigger", action: "popover#toggle"},
        class: "inline-flex items-center justify-center w-6 h-6 text-voodu-muted hover:text-voodu-text hover:bg-voodu-surface-2",
        aria: {label: "Panel options", haspopup: "true"}, title: "Panel options"
      ) { render Icon::EllipsisVerticalOutline.new(class: "w-4 h-4") }

      div(
        hidden: true,
        data: {popover_target: "menu", controller: "panel-options", panel_options_key_value: @metric},
        class: "min-w-[220px] bg-voodu-surface-2 border border-voodu-border shadow-xl overflow-hidden"
      ) do
        div(class: "px-3 py-2 border-b border-voodu-border text-[10.5px] font-semibold uppercase tracking-[0.06em] text-voodu-muted-2 truncate") { @label }

        option_row(text: "Show timeline", kbd: "T", target: "timeline", action: "change->panel-options#toggleTimeline")
        option_row(text: "Show dots", kbd: "D", target: "dots", action: "change->panel-options#toggleDots") if multi?
      end
    end
  end

  # option_row — a popover toggle: label + kbd hint (left), macOS-style switch
  # (right). checked by default; the panel-options controller reflects the stored
  # pref on connect + fires the action.
  def option_row(text:, kbd:, target:, action:)
    label(class: "flex items-center justify-between gap-3 px-3 py-2.5 text-[12px] text-voodu-text-2 hover:bg-voodu-surface cursor-pointer select-none") do
      span(class: "flex items-center gap-2 min-w-0") do
        plain text
        option_kbd(kbd)
      end
      render Components::UI::Switch.new(
        checked: true,
        data: {panel_options_target: target, action: action}
      )
    end
  end

  # option_kbd — the shortcut hint beside an option: pressing the key toggles it
  # while the popover is open (see panel_options_controller).
  def option_kbd(key)
    span(class: "inline-flex items-center justify-center min-w-[16px] h-4 px-1 rounded border border-voodu-border bg-voodu-surface text-[10px] font-voodu-mono text-voodu-muted-2 leading-none") { key }
  end

  # resize_handle — grab strip on the card's edge; mirrors ChartCard so a
  # number tile column-resizes like a chart in the metrics-display grid.
  def resize_handle(edge)
    div(
      data: {action: "pointerdown->metrics-display#startResize", resize_edge: edge},
      aria: {hidden: "true"},
      title: "Drag to resize",
      class: tokens(
        "absolute top-0 bottom-0 w-1.5 cursor-col-resize hover:bg-voodu-accent/30 active:bg-voodu-accent/60 z-10 touch-none",
        (edge == "left") ? "left-0" : "right-0"
      )
    )
  end
end
