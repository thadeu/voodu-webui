# frozen_string_literal: true

# MultiDashboardData — the /metrics data object when several dashboards
# are stacked (?pid=a,b,c). Holds one MetricDashboardData per dashboard,
# in selection order, and exposes the same toolbar surface
# (range/interval/range_ms/dashboard?) the views read, plus `sections`
# (the per-dashboard data objects) + `dashboards` for the header/label.
#
# Each section keeps its OWN display_kind ("dashboard:<id>") so its
# saved hide/reorder layout applies independently when rendered.
class MultiDashboardData
  attr_reader :range, :interval

  def initialize(client, island, dashboards, range:, interval: nil)
    @range = MetricsPageData::RANGES.key?(range) ? range : MetricsPageData::DEFAULT_RANGE
    @interval = MetricsPageData::INTERVALS.include?(interval) ? interval : MetricsPageData::DEFAULT_INTERVAL
    @sections = Array(dashboards).map do |d|
      MetricDashboardData.new(client, island, d, range: @range, interval: @interval)
    end
  end

  # dashboard? — true so the views' toolbar/subtitle branch on a saved
  # view (vs host/pod scope). multi? distinguishes the stacked case.
  def dashboard?
    true
  end

  def multi?
    true
  end

  def empty?
    @sections.empty?
  end

  # sections — the per-dashboard MetricDashboardData objects, in
  # selection order. The views render one stacked block each.
  attr_reader :sections

  def dashboards
    @sections.map(&:dashboard)
  end

  def range_ms
    MetricsPageData.range_to_ms(@range)
  end
end
