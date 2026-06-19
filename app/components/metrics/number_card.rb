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
    truncated: false, clamped: false, series: [], range_ms: nil, sub: nil, default_visible: true)
    @label = label
    @color = color
    @formatted = formatted
    @range = range
    @metric = metric
    @truncated = truncated
    @clamped = clamped
    @series = Array(series)
    @range_ms = range_ms
    @sub = sub
    @default_visible = default_visible
  end

  def view_template
    root_data = {}

    if @metric
      root_data[:metrics_display_target] = "card"
      root_data[:metric_key] = @metric
    end

    root_data[:default_visible] = "false" unless @default_visible

    div(
      class: "relative bg-voodu-surface border border-voodu-border p-3.5 flex flex-col gap-2 min-w-0",
      data: root_data
    ) do
      card_header
      value_block
      sparkline

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

        span(
          class: "inline-flex items-center px-1.5 h-[18px] text-[10.5px] font-medium rounded-voodu-sm " \
                 "border border-voodu-border text-voodu-muted shrink-0 font-voodu-mono"
        ) { @range }
      end

      # sub — the agg + field qualifier ("avg · duration_ms"). Mono because the
      # field is a JSON identifier; muted so it doesn't compete with the label.
      span(class: "text-[10px] font-voodu-mono text-voodu-muted-2 truncate") { @sub } if @sub.present?
    end
  end

  # value_block — the headline number, centered + grown (flex-1) so it lands
  # mid-tile when grid-stretch matches a neighbouring chart's height.
  def value_block
    div(class: "flex-1 flex flex-col items-center justify-center gap-1.5 py-2") do
      div(class: "flex items-baseline gap-1") do
        span(class: "text-voodu-muted text-[22px] font-voodu-mono leading-none") { "≥" } if @truncated
        span(class: "font-voodu-mono text-[40px] vmd:text-[44px] font-semibold leading-none text-voodu-text") { @formatted }
      end

      if @clamped
        span(class: "text-[10.5px] text-voodu-muted-2 text-center px-2") do
          "counted over last #{LogTail::FilePath::RETENTION_DAYS}d (log retention)"
        end
      end
    end
  end

  # sparkline — the count's trend, drawn with the SAME engine as the big
  # charts (Components::Metrics::Chart) in compact mode (axes hidden), so the
  # look matches the rest of /metrics. Needs ≥2 points; the live-scan fallback
  # ships none, so the card stays a clean number until the warehouse fills.
  def sparkline
    return if @series.size < 2

    div(class: "-mx-2 -mb-1.5") do
      render Components::Metrics::Chart.new(
        points: @series,
        color: @color,
        unit: "",
        label: @label,
        range_ms: @range_ms || (60 * 60 * 1000),
        height: 44,
        axes: false
      )
    end
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
