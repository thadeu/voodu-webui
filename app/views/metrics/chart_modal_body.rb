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
#     <toolbar: metric + pod picker + range picker + interval>
#     <chart_block>
#     <stat_strip: min/avg/max>
#   </div>
#
# The pickers all target /metrics/chart with `data-turbo-stream` (the
# metric/pod/interval as anchors, the range as the SAME RangePicker GET form
# the grid uses — so the modal gets the Custom chip too). The endpoint streams
# a fresh ChartModalBody — modal lifecycle is entirely server-driven via
# turbo_stream actions, no Stimulus state to coordinate.
class Views::Metrics::ChartModalBody < Views::Base
  def initialize(chart:, range:, range_ms:, query:, pods: [], current_server: nil, metric_sections: [])
    @chart = chart
    @range = range
    @range_ms = range_ms
    @query = query
    @pods = Array(pods)
    @current_server = current_server
    @metric_sections = Array(metric_sections)
  end

  def view_template
    div(
      id: "chart-modal-body",
      data: {refresh_url: refresh_url},
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
      range_picker_slot
      interval_picker_slot
    end
  end

  # interval_picker_slot — DS dropdown choosing the chart's bucket
  # size. Sits to the RIGHT of the range pills (reading order
  # "range first, then granularity" matches how operators talk
  # about charts — "last 1h, at 5m buckets"). turbo_stream: true
  # so picking an interval swaps the modal body in place without
  # closing.
  def interval_picker_slot
    render Components::Metrics::IntervalPicker.new(
      current: current_interval,
      base_path: metrics_chart_path,
      extra_params: strip_interval_keys(@query),
      turbo_stream: true
    )
  end

  def current_interval
    iv = (@query[:interval] || @query["interval"]).to_s
    iv.presence || "auto"
  end

  # strip_interval_keys — picker rows REPLACE `interval`, so
  # leaving it in extra_params would have the merge order clobber
  # the picker's choice.
  def strip_interval_keys(query)
    query.reject { |k, _| k.to_s == "interval" }
  end

  def metric_picker_slot
    return if @metric_sections.empty?

    render Components::Metrics::MetricPicker.new(
      sections: @metric_sections,
      current_metric: @chart[:metric] || @query[:metric] || @query["metric"],
      base_path: metrics_chart_path,
      extra_params: strip_metric_keys(@query),
      turbo_stream: true
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
    sid = (@query[:scope_id] || @query["scope_id"]).to_s

    render Components::Metrics::PodPicker.new(
      scope_kind: sk.presence || "host",
      scope_id: sid,
      current_server: @current_server,
      pods: @pods,
      base_path: metrics_chart_path,
      extra_params: strip_scope_keys(@query),
      turbo_stream: true,
      hide_host: false
    )
  end

  # strip_scope_keys — the picker REPLACES scope_kind/scope_id in
  # each row's URL, so we shouldn't pre-seed them via extra_params
  # (otherwise the merge order would clobber the picker's choice).
  def strip_scope_keys(query)
    query.reject { |k, _| %w[scope_kind scope_id].include?(k.to_s) }
  end

  # range_picker_slot — the SAME control the grid page uses
  # (Components::Metrics::RangePicker): preset pills + a Custom chip with a
  # From/Until popover. turbo_stream:true so a preset OR an applied custom
  # window swaps the modal body in place. This is what closes the gap — the
  # modal used to offer presets only, so a brushed (custom) window couldn't be
  # seen or edited without leaving the modal.
  def range_picker_slot
    render Components::Metrics::RangePicker.new(
      range: @range,
      custom: modal_custom_window?,
      from_iso: @query[:from] || @query["from"],
      until_iso: @query[:until] || @query["until"],
      extra_params: strip_range_keys(@query),
      base_path: metrics_chart_path,
      turbo_stream: true
    )
  end

  def modal_custom_window?
    (@query[:range] || @query["range"]).to_s == "custom"
  end

  # strip_range_keys — the RangePicker owns range/from/until (its hidden
  # inputs), so leaving them in extra_params would double them up on submit.
  def strip_range_keys(query)
    query.reject { |k, _| %w[range from until].include?(k.to_s) }
  end

  # chart_block — the chart itself. height: 480 is roughly 2.4x
  # the inline ChartCard's 200, which is the whole point. axes:true
  # gets the y-tick labels + x-tick timestamps back (the inline
  # ChartCard hides them on the small grid; in the modal there's
  # room).
  #
  # width: 1600 matches the modal dialog's w-[min(1600px,...)] so the pre-JS
  # viewBox is already about the right aspect; the responsive controller then
  # measures the real container width and refills to fit. Chart.rb dropped
  # preserveAspectRatio="none" so the viewBox keeps its real aspect ratio —
  # text + dots stay round/legible.
  def chart_block
    if gauge?
      div(class: "bg-voodu-surface border border-voodu-border p-3.5 flex items-center justify-center min-h-[360px]") do
        if @chart[:chart_type].to_s == "gauge_radial"
          render Components::Metrics::GaugeRadial.new(
            pct: gauge_pct, color: @chart[:color], sub_label: gauge_sub_label, max_w: 360
          )
        else
          div(class: "w-full max-w-[560px]") do
            render Components::Metrics::GaugeLinear.new(
              pct: gauge_pct, color: @chart[:color],
              value_label: gauge_value_label, capacity_label: @chart[:capacity_label]
            )
          end
        end
      end
    else
      div(class: "bg-voodu-surface border border-voodu-border p-3.5") do
        render Components::Metrics::Chart.new(
          points: @chart[:points],
          color: @chart[:color],
          unit: @chart[:unit],
          label: @chart[:label],
          range_ms: @range_ms,
          width: 1600,
          height: 480,
          axes: true,
          # In the modal, brush-to-zoom re-fetches THIS endpoint at the
          # brushed window instead of navigating away (which tears the
          # modal down). refresh_url already carries every chart param.
          zoom_url: refresh_url
        )
      end
    end
  end

  # Gauge envelope readers — mirror ChartCard's logic (capacity metric →
  # capacity_pct; percent metric → the value itself); nil → no ceiling,
  # so chart_block falls back to the area chart.
  def gauge?
    %w[gauge_radial gauge_linear].include?(@chart[:chart_type].to_s) && !gauge_pct.nil?
  end

  def gauge_pct
    return @chart[:capacity_pct] unless @chart[:capacity_pct].nil?
    return current_value if percent_unit?

    nil
  end

  def current_value
    @chart[:current] || (Array(@chart[:points]).last || {})[:value]
  end

  def gauge_sub_label
    return nil unless @chart[:capacity_label]

    v = current_value
    return @chart[:capacity_label] if v.nil?

    "#{MetricFormat.number(v)} / #{@chart[:capacity_label]}"
  end

  def gauge_value_label
    return nil if percent_unit? || @chart[:capacity_label].nil?

    v = current_value
    v.nil? ? nil : "#{MetricFormat.number(v)} #{@chart[:unit]}".strip
  end

  def stat_strip
    s = stats

    div(class: "flex items-center flex-wrap gap-4 px-1") do
      # Capacity context on the LEFT — pairs the headline current
      # value with the host/pod's total, mirroring the chart card
      # header on /metrics ("21.9 GB / 39 GB · 56%"). Only renders
      # for metrics that HAVE a meaningful total (memory + disk);
      # CPU, HTTP counters, network rates pass through with the
      # min/avg/max strip starting flush-left.
      capacity_chip if @chart[:capacity_label] && !gauge?

      stat_chip("min", s[:min])
      stat_chip("avg", s[:avg])
      stat_chip("max", s[:max])
    end
  end

  # capacity_chip — "21.9 GB / 39 GB · 56%" cluster. Current value
  # comes from MetricsPageData's `current` (unaggregated latest),
  # falling back to series.last when the API hasn't shipped a
  # latest yet (cold boot). Capacity + percentage are echoed from
  # the same `capacity_for` resolution that drives the card header
  # — both surfaces speak one dialect.
  def capacity_chip
    cur = @chart[:current] || (Array(@chart[:points]).last || {})[:value]
    cur_fmt = format_value(cur)

    span(class: "text-[12px] font-voodu-mono text-voodu-muted") do
      # current value carries its own unit suffix when the unit isn't
      # baked into the formatter (percent units already include "%";
      # MB/GB don't — match the card-header rendering policy).
      span(class: "text-voodu-text font-semibold") { cur_fmt }
      unless percent_unit?
        plain " "
        span { @chart[:unit].to_s }
      end
      plain " / #{@chart[:capacity_label]}"
      if @chart[:capacity_pct]
        plain " · "
        span(class: "text-voodu-text-2") { "#{@chart[:capacity_pct]}%" }
      end
    end
  end

  def percent_unit?
    @chart[:unit].to_s == "%"
  end

  def stat_chip(label, value)
    span(class: "text-[12px] font-voodu-mono text-voodu-muted") do
      plain "#{label} "
      span(class: "text-voodu-text font-semibold") { format_value(value) }
    end
  end

  def stats
    pts = Array(@chart[:points])
    return {min: nil, max: nil, avg: nil} if pts.empty?

    vs = pts.map { |p| p[:value].to_f }

    {min: vs.min, max: vs.max, avg: vs.sum / vs.size}
  end

  def format_value(v)
    return "—" if v.nil?

    (@chart[:unit].to_s == "%") ? MetricFormat.percent(v) : MetricFormat.number(v)
  end
end
