# frozen_string_literal: true

# Components::Metrics::IntervalPicker — dropdown that controls the
# chart's bucket size (the x-axis density) INDEPENDENTLY from the
# range pills. Range answers "how far back?"; interval answers
# "how granular?".
#
# Why a separate control instead of preset range/interval pairs:
# operator flexibility. The same "last 1h" can be examined at 1m
# (60 spikes) or 5m (12 smoothed points) depending on what they're
# hunting — a burst hidden in the average vs the overall trend.
#
# Mirrors the DS dropdown pattern of Components::Metrics::MetricPicker
# (same `data-controller="dropdown"`, same trigger/menu structure)
# so the modal toolbar reads as a row of consistent pickers.
#
# Mounted on:
#   - Views::Metrics::Index (page toolbar, next to the RangePicker)
#   - Views::Metrics::ChartModalBody (modal toolbar, next to the
#     range pills + metric picker + pod picker)
#
# URL contract: the active interval lives in the `interval` query
# param. `auto` is the default and is OMITTED from the URL (clean
# URLs by default — operator only sees the param when they've
# explicitly picked one).
class Components::Metrics::IntervalPicker < Components::Base
  # Drop OPTIONS in lockstep with MetricsPageData::INTERVALS and
  # MetricsWarehouse::INTERVAL_ALIASES keys. Drift between any of
  # the three = picker rows that silently roundtrip to "auto".
  OPTIONS = %w[auto 1s 10s 15s 1m 5m 15m 30m 1h].freeze

  # current:      currently active interval (e.g. "auto", "1m")
  # base_path:    URL each row hits (metrics_path or metrics_chart_path)
  # extra_params: merged into every URL EXCEPT `interval` (which the
  #               picker overrides per row). Pass the request query
  #               minus `interval`.
  # turbo_stream: emit data-turbo-stream on row anchors so the swap
  #               stays modal-local (used inside the modal toolbar).
  #               Defaults to false for the page-level picker which
  #               does a normal navigation.
  def initialize(current:, base_path:, extra_params: {}, turbo_stream: false)
    @current      = current.to_s.presence || "auto"
    @base_path    = base_path
    @extra_params = extra_params || {}
    @turbo_stream = turbo_stream
  end

  def view_template
    div(class: "relative", data: { controller: "dropdown" }) do
      trigger
      menu
    end
  end

  private

  def trigger
    button(
      type: "button",
      data: { action: "click->dropdown#toggle" },
      class: "inline-flex items-center gap-2 px-2.5 h-9 min-w-[140px] border border-voodu-border bg-voodu-surface text-voodu-text text-[12.5px] hover:bg-voodu-surface-2"
    ) do
      span(class: "min-w-0 truncate") do
        span(class: "text-voodu-muted") { "every " }
        span(class: "font-voodu-mono text-voodu-text") { @current }
      end

      div(class: "flex-1")
      render Icon::ChevronDownOutline.new(class: "w-2.5 h-2.5 text-voodu-muted")
    end
  end

  def menu
    div(
      hidden: true,
      data: { dropdown_target: "menu" },
      class: "absolute left-0 top-[calc(100%+4px)] z-30 min-w-[160px] max-h-[360px] overflow-auto scrollbar-hidden border border-voodu-border-2 bg-voodu-surface-2 shadow-2xl"
    ) do
      OPTIONS.each { |opt| option_row(opt) }
    end
  end

  def option_row(opt)
    active = opt == @current

    a(
      href: build_url(opt),
      data: @turbo_stream ? { turbo_stream: "true" } : { turbo: false },
      class: tokens(
        "flex items-center gap-2.5 w-full px-3 py-2 min-h-[34px] text-left",
        active ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text hover:bg-voodu-hover"
      )
    ) do
      span(
        class: tokens(
          "font-voodu-mono text-[12.5px] truncate flex-1",
          active ? "font-semibold text-voodu-accent-2" : "font-medium text-voodu-text"
        )
      ) { opt }

      if active
        render Icon::CheckOutline.new(class: "w-3 h-3 text-voodu-accent-2 shrink-0 ml-1")
      end
    end
  end

  # build_url — picker rows override `interval` and leave the rest
  # of the query untouched. `auto` is OMITTED from the URL so the
  # default state reads as `?range=1h` instead of `?range=1h&interval=auto`.
  def build_url(opt)
    params = @extra_params.dup
    params[:interval] = opt unless opt == "auto"

    qs = params.to_query
    qs.empty? ? @base_path.to_s : "#{@base_path}?#{qs}"
  end
end
