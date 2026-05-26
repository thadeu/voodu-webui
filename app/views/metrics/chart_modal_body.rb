# frozen_string_literal: true

# Views::Metrics::ChartModalBody — content of the chart-expand
# modal. Rendered into the SHARED #chart-modal-body container (see
# Components::Metrics::ChartModal) via a turbo_stream `replace`
# action. Whenever the operator opens, switches pod, or switches
# range, MetricsController#chart returns a stream containing a
# fresh ChartModalBody — Turbo swaps the DOM in place, modal
# stays visible.
#
# This replaces the previous Turbo Frame approach (per-card
# overlays, JS portal, per-metric frame ids). Now the layout is:
#
#   <div id="chart-modal-body">     ← turbo_stream replace target
#     <toolbar: pod picker + range pills>
#     <chart_block>
#     <stat_strip: min/avg/max>
#   </div>
#
# Pod picker + range pills are anchors with `data-turbo-stream`
# pointing at /metrics/chart with updated params. The same
# endpoint streams a new ChartModalBody — modal lifecycle is
# entirely server-driven via turbo_stream actions, no Stimulus
# state to coordinate.
class Views::Metrics::ChartModalBody < Views::Base
  def initialize(chart:, range:, range_ms:, query:, pods: [], current_island: nil, metric_sections: [])
    @chart           = chart
    @range           = range
    @range_ms        = range_ms
    @query           = query
    @pods            = Array(pods)
    @current_island  = current_island
    @metric_sections = Array(metric_sections)
  end

  def view_template
    div(
      id:    "chart-modal-body",
      data:  { refresh_url: refresh_url },
      class: "flex flex-col gap-3 p-4 vmd:p-5"
    ) do
      toolbar
      chart_block
      stat_strip
    end
  end

  # refresh_url — the URL the broadcast tick refetches when the
  # modal is open. Identical to the URL the operator's last
  # picker action GET'd, so the refresh stays scoped to the
  # current metric/pod/range without sending the operator back
  # to a "default" view they didn't pick.
  #
  # Read by turbo_actions/metrics.js when `chart-modal:opened`
  # is true and a metrics_tick fires.
  def refresh_url
    "#{metrics_chart_path}?#{@query.to_query}"
  end

  private

  # toolbar — metric picker + pod picker (left) + range pills
  # (right). All three controls trigger /metrics/chart via
  # turbo_stream; the response replaces THIS whole
  # `#chart-modal-body` div in place, while leaving the modal
  # scaffold (title bar, dialog) untouched — so the modal stays
  # open across switches.
  #
  # Reading order left→right: "WHAT am I looking at" (metric) →
  # "OF WHOM" (pod) → "WHEN" (range). Most fundamental switch
  # gets the leftmost slot.
  def toolbar
    div(class: "flex items-center flex-wrap gap-2") do
      metric_picker_slot
      pod_picker_slot
      span(class: "flex-1")
      range_pills
    end
  end

  def metric_picker_slot
    return if @metric_sections.empty?

    render Components::Metrics::MetricPicker.new(
      sections:       @metric_sections,
      current_metric: @chart[:metric] || @query[:metric] || @query["metric"],
      base_path:      metrics_chart_path,
      extra_params:   strip_metric_keys(@query),
      turbo_stream:   true
    )
  end

  # strip_metric_keys — picker rows REPLACE metric/scale/label/
  # color/unit, so pre-seeding via extra_params would have the
  # merge order clobber the picker's choice. Keep everything else
  # (scope_kind/scope_id/range).
  def strip_metric_keys(query)
    query.reject { |k, _| %w[metric scale label color unit].include?(k.to_s) }
  end

  # pod_picker_slot — DS Components::Metrics::PodPicker with
  # `frame_target: nil` (no turbo-frame to swap into anymore) and
  # `extra_params:` carrying metric/scale/label/color/unit so the
  # /metrics/chart endpoint can rebuild the right single-chart
  # context. The picker's anchors already opt into turbo_stream
  # via `data-turbo-stream` (added in the picker for this refactor).
  #
  # `hide_host: false` keeps the HOST row reachable so operators
  # can drill host↔pod within the same modal session.
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
      turbo_stream:   true,
      hide_host:      false
    )
  end

  # strip_scope_keys — the picker REPLACES scope_kind/scope_id in
  # each row's URL, so we shouldn't pre-seed them via extra_params
  # (otherwise the merge order would clobber the picker's choice).
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
          data: { turbo_stream: "true" },
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
  # Chart.rb dropped preserveAspectRatio="none" so the viewBox keeps
  # its real aspect ratio — text + dots stay round/legible.
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
