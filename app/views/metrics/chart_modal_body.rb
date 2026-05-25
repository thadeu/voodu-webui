# frozen_string_literal: true

# Views::Metrics::ChartModalBody — the standalone single-chart view
# loaded by the maximize-into-modal flow on /metrics.
#
# Wrapped in `<turbo-frame id="chart-modal-frame">`. The same frame
# id is targeted by the range picker inside the modal — clicking a
# pill GETs /metrics/chart?range=NEW (with the rest of the query
# preserved) and Turbo swaps just this body. The modal stays open;
# the parent page's range is NOT touched (modal-local scope, the
# explicit decision when this feature was added).
#
# Layout: chart on top (full available width × tall), pills + meta
# strip below. Stat chips (min/avg/max) sit RIGHT of the pills so
# operators get both controls and at-a-glance numerics in one row.
class Views::Metrics::ChartModalBody < Views::Base
  RANGES = %w[5m 15m 1h 6h 24h 7d].freeze

  def initialize(chart:, range:, range_ms:, query:)
    @chart    = chart
    @range    = range
    @range_ms = range_ms
    @query    = query
  end

  def view_template
    turbo_frame_tag("chart-modal-frame", class: "block") do
      div(class: "flex flex-col gap-3 p-4 vmd:p-5") do
        toolbar
        chart_block
        stat_strip
      end
    end
  end

  private

  # toolbar — label + range pills. Range pills are anchors that
  # GET the same /metrics/chart with `range=` swapped; Turbo
  # extracts the matching `<turbo-frame id="chart-modal-frame">`
  # from the response and swaps in place.
  def toolbar
    div(class: "flex items-center flex-wrap gap-3") do
      span(
        class: "text-[12px] font-semibold uppercase tracking-[0.06em] font-voodu-mono",
        style: "color: #{@chart[:color]};"
      ) { @chart[:label] }

      span(
        class: "font-voodu-mono text-[20px] font-semibold text-voodu-text"
      ) { headline }

      span(class: "flex-1")

      range_pills
    end
  end

  def range_pills
    div(
      role: "tablist",
      aria: { label: "Time range" },
      class: "inline-flex items-stretch border border-voodu-border bg-voodu-surface"
    ) do
      RANGES.each_with_index do |r, i|
        active = r == @range

        a(
          href: range_url(r),
          role: "tab",
          aria: { selected: active.to_s },
          class: tokens(
            "inline-flex items-center justify-center min-w-9 px-2.5 h-8 font-voodu-mono text-[11px] font-bold",
            i.positive? ? "border-l border-voodu-border" : nil,
            active ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text-2 hover:bg-voodu-surface-2"
          )
        ) { r }
      end
    end
  end

  # chart_block — the chart itself. height: 480 is roughly 2.4x
  # the inline ChartCard's 200, which is the whole point. axes:true
  # gets the y-tick labels + x-tick timestamps back (the inline
  # ChartCard hides them on the small grid; in the modal there's
  # room).
  def chart_block
    div(class: "bg-voodu-surface border border-voodu-border p-3.5") do
      render Components::Metrics::Chart.new(
        points:   @chart[:points],
        color:    @chart[:color],
        unit:     @chart[:unit],
        label:    @chart[:label],
        range_ms: @range_ms,
        height:   480,
        axes:     true
      )
    end
  end

  # stat_strip — min/avg/max in a strip below the chart. Same
  # values + formatting the inline ChartCard's header strip uses,
  # but full-width (more breathing room) and mono throughout.
  def stat_strip
    s = stats

    div(class: "flex items-center flex-wrap gap-4 px-1") do
      stat_chip("min", s[:min])
      stat_chip("avg", s[:avg])
      stat_chip("max", s[:max])
    end
  end

  def stat_chip(label, value)
    span(class: "text-[12px] font-voodu-mono text-voodu-muted") do
      plain "#{label} "
      span(class: "text-voodu-text font-semibold") { format_value(value) }
    end
  end

  def headline
    return "—" if @chart[:current].nil?

    base = format_value(@chart[:current])
    unit = @chart[:unit].to_s
    return base if unit.empty? || base.include?(unit)

    "#{base} #{unit}"
  end

  def stats
    pts = Array(@chart[:points])
    return { min: nil, max: nil, avg: nil } if pts.empty?

    vs = pts.map { |p| p[:value].to_f }

    { min: vs.min, max: vs.max, avg: vs.sum / vs.size }
  end

  def format_value(v)
    return "—" if v.nil?

    @chart[:unit].to_s == "%" ? MetricFormat.percent(v) : MetricFormat.number(v)
  end

  # range_url — same as Components::Metrics::RangePicker but with
  # the modal endpoint as base. Preserves every other query param
  # (metric, scope, color, etc.) so Turbo's response carries the
  # right context.
  def range_url(r)
    "#{metrics_chart_path}?#{@query.merge(range: r).to_query}"
  end
end
