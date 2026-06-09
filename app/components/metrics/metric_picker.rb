# frozen_string_literal: true

# Components::Metrics::MetricPicker — pick which metric the
# chart-expand modal shows, without closing the modal.
#
# Mounted in Views::Metrics::ChartModalBody#toolbar alongside the
# pod picker and range pills. Operator can swap CPU → Memory →
# Requests etc. while staying in the same modal session — same
# pattern CloudWatch / Grafana use.
#
# Visual: a `<select>`-like dropdown trigger styled with the
# active metric's color (so the eye registers "I'm looking at
# REQUESTS" in orange without reading the label). Options grouped
# into RESOURCE / HTTP sections, each row prefixed by a colored
# square (the chart's color token) for cross-reference with the
# chart palette rule (1 metric = 1 color, see CLAUDE.md).
#
# This is a metric-aware dropdown — distinct from
# Components::UI::ScopePicker which is built around host/pod rows
# with status dots. The structures don't overlap enough to share;
# keeping this component thin (~80 LOC) and dedicated keeps the
# rendering straightforward without an over-abstracted DS base.
class Components::Metrics::MetricPicker < Components::Base
  # sections: [{ label: "RESOURCE", specs: [spec_hash, ...] }, ...]
  #   where each spec is the same shape MetricsPageData ships:
  #     { metric:, label:, color:, unit:, scale: }
  #
  # current_metric: the metric key currently active (e.g. "cpu_percent")
  # base_path / extra_params: same opt-in as Components::Metrics::PodPicker —
  #   builds row hrefs that hit /metrics/chart with the swap applied,
  #   preserving everything else in the URL.
  # turbo_stream: when true, anchor rows emit data-turbo-stream="true"
  #   so the swap stays modal-local (Turbo handles the response as a
  #   stream, no full-page navigation).
  def initialize(sections:, current_metric:, base_path:, extra_params: {}, turbo_stream: true)
    @sections       = Array(sections)
    @current_metric = current_metric.to_s
    @base_path      = base_path
    @extra_params   = extra_params || {}
    @turbo_stream   = turbo_stream
  end

  def view_template
    div(class: "relative", data: { controller: "dropdown" }) do
      trigger
      menu
    end
  end

  private

  def trigger
    spec = current_spec

    button(
      type: "button",
      data: { action: "click->dropdown#toggle" },
      class: "inline-flex items-center gap-2 px-2.5 h-9 min-w-[180px] border border-voodu-border bg-voodu-surface text-voodu-text text-[12.5px] hover:bg-voodu-surface-2"
    ) do
      color_square(spec ? spec[:color] : "var(--voodu-muted)")

      span(class: "min-w-0 truncate") do
        span(class: "text-voodu-muted") { "metric " }
        span(class: "font-voodu-mono text-voodu-text") { spec ? spec[:label].to_s : "—" }
      end

      div(class: "flex-1")
      render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 text-voodu-muted")
    end
  end

  def menu
    div(
      hidden: true,
      data: { dropdown_target: "menu" },
      class: "absolute left-0 top-[calc(100%+4px)] z-30 min-w-[240px] max-w-[320px] max-h-[420px] overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface shadow-2xl"
    ) do
      @sections.each do |section|
        section_label(section[:label])
        Array(section[:specs]).each { |spec| option_row(spec) }
      end
    end
  end

  def section_label(text)
    div(
      class: "px-3 py-1.5 text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted bg-voodu-bg-2 border-y border-voodu-border"
    ) { text }
  end

  def option_row(spec)
    active = spec[:metric].to_s == @current_metric

    a(
      href: build_url(spec),
      data: @turbo_stream ? { turbo_stream: "true" } : { turbo: false },
      class: tokens(
        "flex items-center gap-2.5 w-full px-3 py-2 min-h-[34px] text-left",
        active ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text hover:bg-voodu-hover"
      )
    ) do
      color_square(spec[:color])

      span(
        class: tokens(
          "font-voodu-mono text-[12.5px] truncate flex-1",
          active ? "font-semibold text-voodu-accent-2" : "font-medium text-voodu-text"
        )
      ) { spec[:label].to_s }

      span(class: "text-[10.5px] text-voodu-muted-2 font-voodu-mono") { spec[:unit].to_s.presence || "—" }

      if active
        render Icon::CheckOutline.new(class: "w-3 h-3 text-voodu-accent-2 shrink-0 ml-1")
      end
    end
  end

  # color_square — the 1-metric-1-color visual cue. Solid square
  # in the metric's CSS-var color, matched against the chart's
  # stroke so an operator scanning the dropdown can pattern-match
  # by tint instead of reading every label.
  def color_square(color)
    span(
      class: "inline-block w-2.5 h-2.5 shrink-0",
      style: "background: #{color};"
    )
  end

  def current_spec
    @sections.flat_map { |s| Array(s[:specs]) }.find { |spec| spec[:metric].to_s == @current_metric }
  end

  # build_url — picker rows override metric/scale/label/color/unit
  # (each spec carries all five) and leave the rest of the query
  # untouched (scope_kind/scope_id/range/etc.). Same merge pattern
  # as PodPicker so behaviour stays consistent.
  def build_url(spec)
    params = @extra_params.merge(
      metric: spec[:metric],
      scale:  spec[:scale],
      label:  spec[:label],
      color:  spec[:color],
      unit:   spec[:unit]
    )

    "#{@base_path}?#{params.to_query}"
  end
end
