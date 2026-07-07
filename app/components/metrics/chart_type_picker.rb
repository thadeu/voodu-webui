# frozen_string_literal: true

# Components::Metrics::ChartTypePicker — dropdown that switches how the metric
# is drawn: Area (time-series line+fill), Radial (semicircle gauge), or Linear
# (capacity bar gauge). Same DS dropdown chrome as IntervalPicker/MetricPicker
# so the modal toolbar reads as a consistent row of pickers.
#
# Why it exists: chart_type used to stick to whatever the panel opened as, with
# no way to change it in the modal — open a gauge, switch metric/pod, and it
# stayed a gauge. This gives the operator explicit control.
#
# URL contract: the active type lives in the `chart_type` query param. `area`
# is the default and is OMITTED (clean URLs), so the param only appears once
# the operator picks a gauge. Gauges silently fall back to area for metrics
# without a percentage/capacity ceiling (same as ChartCard), so all three are
# always offerable.
class Components::Metrics::ChartTypePicker < Components::Base
  DEFAULT = "area"

  # The type list + labels + glyphs are Components::Metrics::ChartShape's — one
  # source of truth shared with the dashboard builder's shape chips.
  OPTIONS = Components::Metrics::ChartShape::METRIC_TYPES
  LABELS = Components::Metrics::ChartShape::LABELS

  # current:      active chart_type (e.g. "area", "gauge_radial")
  # base_path:    URL each row hits (metrics_path or metrics_chart_path)
  # extra_params: merged into every URL EXCEPT `chart_type` (the picker owns
  #               it per row). Pass the request query minus `chart_type`.
  # turbo_stream: emit data-turbo-stream so the swap stays modal-local.
  def initialize(current:, base_path:, extra_params: {}, turbo_stream: false)
    @current = current.to_s.presence || DEFAULT
    @base_path = base_path
    @extra_params = extra_params || {}
    @turbo_stream = turbo_stream
  end

  def view_template
    div(class: "relative", data: {controller: "dropdown"}) do
      trigger
      menu
    end
  end

  private

  def trigger
    button(
      type: "button",
      data: {action: "click->dropdown#toggle"},
      class: "inline-flex items-center gap-2 px-2.5 h-9 min-w-[130px] border border-voodu-border bg-voodu-surface text-voodu-text text-[12.5px] hover:bg-voodu-surface-2"
    ) do
      render Components::Metrics::ChartShape.new(type: @current, css: "w-5 h-4 shrink-0 text-voodu-muted")

      span(class: "min-w-0 truncate") do
        span(class: "text-voodu-muted") { "type " }
        span(class: "text-voodu-text") { LABELS[@current] || "Area" }
      end

      div(class: "flex-1")
      render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 text-voodu-muted")
    end
  end

  def menu
    div(
      hidden: true,
      data: {dropdown_target: "menu"},
      class: "absolute left-0 top-[calc(100%+4px)] z-30 min-w-[150px] border border-voodu-border-2 bg-voodu-surface shadow-2xl"
    ) do
      OPTIONS.each { |t| option_row(t[:value], t[:label]) }
    end
  end

  def option_row(value, label)
    active = value == @current

    a(
      href: build_url(value),
      data: @turbo_stream ? {turbo_stream: "true"} : {turbo: false},
      class: tokens(
        "flex items-center gap-2.5 w-full px-3 py-2 min-h-[34px] text-left",
        active ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text hover:bg-voodu-hover"
      )
    ) do
      render Components::Metrics::ChartShape.new(type: value, css: "w-6 h-4 shrink-0")

      span(
        class: tokens(
          "text-[12.5px] truncate flex-1",
          active ? "font-semibold text-voodu-accent-2" : "font-medium text-voodu-text"
        )
      ) { label }

      if active
        render Icon::CheckOutline.new(class: "w-3 h-3 text-voodu-accent-2 shrink-0 ml-1")
      end
    end
  end

  # build_url — override `chart_type`, leave the rest untouched. `area` is
  # OMITTED so switching back to the default drops the param entirely.
  def build_url(value)
    params = @extra_params.dup
    params[:chart_type] = value unless value == DEFAULT

    qs = params.to_query
    qs.empty? ? @base_path.to_s : "#{@base_path}?#{qs}"
  end
end
