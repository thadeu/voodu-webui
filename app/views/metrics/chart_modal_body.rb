# frozen_string_literal: true

# Views::Metrics::ChartModalBody — the standalone single-chart view
# loaded by the maximize-into-modal flow on /metrics.
#
# Wrapped in `<turbo-frame id="{frame_id}">`. The same id is targeted
# by the range picker + pod picker inside the modal — clicking either
# control GETs /metrics/chart with the matching param swapped (with
# the rest of the query preserved) and Turbo swaps just this body.
# The modal stays open; the parent page's state is NOT touched
# (modal-local scope, the explicit decision when this feature was
# added).
#
# Per-metric frame_id (`chart-modal-cpu_percent`, `chart-modal-req_count`)
# is critical: the eight ChartCards on /metrics each render their own
# hidden modal, so without unique ids `document.getElementById` would
# always resolve to the FIRST frame in the DOM (CPU's) regardless of
# which modal is actually open — the previous bug operators saw as
# "trocou pod no select e valor continua antigo."
#
# Layout: pod picker + range pills on top, chart in the middle, min/
# avg/max strip at the bottom.
class Views::Metrics::ChartModalBody < Views::Base
  def initialize(chart:, range:, range_ms:, query:, frame_id:, pods: [], current_island: nil)
    @chart          = chart
    @range          = range
    @range_ms       = range_ms
    @query          = query
    @frame_id       = frame_id
    @pods           = Array(pods)
    @current_island = current_island
  end

  def view_template
    turbo_frame_tag(@frame_id, class: "block") do
      div(class: "flex flex-col gap-3 p-4 vmd:p-5") do
        toolbar
        chart_block
        stat_strip
      end
    end
  end

  private

  # toolbar — pod picker (left) + range pills (right).
  #
  # Pod picker: DS Components::Metrics::PodPicker, wired with
  # `frame_target: @frame_id` so Turbo swaps inside this modal
  # instead of doing a full navigation. `base_path: metrics_chart_path`
  # + `extra_params: @query` make the picker's URLs hit the modal
  # endpoint preserving the rest of the context (metric/scale/range).
  #
  # Range pills: anchors that GET /metrics/chart with `range=` swapped,
  # targeting `@frame_id`. Same Turbo swap mechanic.
  def toolbar
    div(class: "flex items-center flex-wrap gap-3") do
      pod_picker_slot
      span(class: "flex-1")
      range_pills
    end
  end

  # pod_picker_slot — renders the scope picker (HOST + pods) in
  # every modal, regardless of the current scope. Earlier
  # iterations early-returned when the scope wasn't "pod" — the
  # picker was missing on /metrics?scope_kind=host modals,
  # leaving the operator no way to drill into a pod without
  # closing + reopening. Always rendering keeps the navigation
  # affordance available from any starting point.
  #
  # `hide_host: false` so the HOST row stays reachable too —
  # operator can swap pod↔host within a single modal session
  # for metrics that exist in both scopes (cpu_percent). For
  # metrics that don't (e.g. req_count is ingress-only, no host
  # equivalent), switching to host returns "no data" honestly —
  # the chart speaks for itself.
  def pod_picker_slot
    sk = (@query[:scope_kind] || @query["scope_kind"]).to_s
    sid = (@query[:scope_id]  || @query["scope_id"]).to_s

    render Components::Metrics::PodPicker.new(
      scope_kind:     sk.presence || "host",
      scope_id:       sid,
      current_island: @current_island,
      pods:           @pods,
      base_path:      metrics_chart_path,
      extra_params:   strip_scope_keys(@query),
      frame_target:   @frame_id,
      hide_host:      false
    )
  end

  # strip_scope_keys — the picker REPLACES scope_kind/scope_id in
  # each row's URL, so we shouldn't pre-seed them via extra_params
  # (otherwise the merge order would clobber the picker's choice).
  # Pass everything else through unchanged.
  def strip_scope_keys(query)
    query.reject { |k, _| %w[scope_kind scope_id].include?(k.to_s) }
  end

  RANGES = %w[5m 15m 1h 6h 24h 7d].freeze

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
          data: { turbo_frame: @frame_id },
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
  #
  # width: 1100 matches the modal dialog's max-w-[min(1100px,...)].
  # Passing it explicitly lets the Chart's viewBox keep its real
  # aspect ratio (Chart.rb drops preserveAspectRatio="none" since
  # 2026-05-25 so SVG text doesn't stretch horizontally — this width
  # ensures the viewBox = container, near-zero scaling distortion).
  def chart_block
    div(class: "bg-voodu-surface border border-voodu-border p-3.5") do
      render Components::Metrics::Chart.new(
        points:   @chart[:points],
        color:    @chart[:color],
        unit:     @chart[:unit],
        label:    @chart[:label],
        range_ms: @range_ms,
        width:    1100,
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
