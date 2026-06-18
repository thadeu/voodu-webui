# frozen_string_literal: true

# Components::Metrics::RangePicker — pill group selecting the time
# range for the metrics charts. 1m / 5m / 15m / 1h / 6h / 24h / 7d.
#
# Same shape as the inspiration's RANGES table; each pill is a
# link that submits a GET to /metrics?range=<id>, preserving the
# active scope params so the operator can range-flip without
# losing their scope selection.
#
# 1m is the "near-real-time" pill: with the metrics_sync job firing
# every 14s and a 15s bucket size, an operator on /metrics?range=1m
# sees ~4 data points refreshing live — useful for watching
# requests/min during a release window.
class Components::Metrics::RangePicker < Components::Base
  RANGES = %w[1m 5m 15m 1h 6h 24h 7d].freeze

  def initialize(range:)
    @range = range
  end

  def view_template
    div(
      role: "tablist",
      aria: {label: "Time range"},
      class: "inline-flex items-stretch border border-voodu-border bg-voodu-surface"
    ) do
      RANGES.each_with_index do |r, i|
        active = r == @range

        a(
          href: range_url(r),
          data: {turbo: false},
          role: "tab",
          aria: {selected: active.to_s},
          class: tokens(
            "inline-flex items-center justify-center min-w-9 px-2.5 h-8 font-voodu-mono text-[11px] font-bold",
            i.positive? ? "border-l border-voodu-border" : nil,
            active ? "bg-voodu-accent-dim text-voodu-accent-2" : "text-voodu-text-2 hover:bg-voodu-surface-2"
          )
        ) { r }
      end
    end
  end

  private

  def range_url(r)
    params = request.query_parameters.merge(range: r)
    "#{metrics_path}?#{params.to_query}"
  end
end
