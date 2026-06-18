# frozen_string_literal: true

# MetricDashboard — a named, operator-saved collection of metric panels.
#
# Each panel is a (source, metric) pair captured verbatim from the metric
# catalog (MetricsPageData.metric_catalog_for), so rendering needs no
# lookup — just hand each panel to MetricsPageData#single_chart. `panels`
# is a native JSON column (Array of Hashes); Active Record (de)serializes
# it, so callers read/write `dashboard.panels` as a plain Ruby Array.
#
# Panel identity is WORKLOAD-level for pods: `scope` + `name` (e.g.
# web/web), never a container id — so the dashboard survives a redeploy.
# MetricDashboardData resolves the current running replica at render time.
#
# Pinning: at most one dashboard per island is pinned. The pinned one is
# what /metrics opens to. `pin!` clears siblings in the same transaction
# (the partial unique index is the DB backstop).
class MetricDashboard < ApplicationRecord
  belongs_to :island

  # Required keys every panel must carry (non-blank). `unit` is NOT here
  # — several metrics are legitimately unit-less (Requests, Net Rx/Tx,
  # error counts, Bytes Out all carry unit ""), so it only needs to
  # exist, not be present. Pod panels additionally need scope/name to
  # resolve the live replica; host panels don't.
  PANEL_KEYS = %w[scope_kind metric scale label color].freeze
  POD_PANEL_KEYS = %w[scope name].freeze

  # Optional per-panel chart type. Absent → ChartCard defaults to "area".
  CHART_TYPES = %w[area gauge_radial gauge_linear].freeze

  # Bound the per-render fan-out — each panel is its own metric fetch.
  MAX_PANELS = 12

  validates :name, presence: true, length: {maximum: 128},
    uniqueness: {scope: :island_id}
  validate :panels_well_formed

  before_create :ensure_uuid

  # to_param — URLs use the opaque uuid, not the sequential integer id.
  # set_dashboard / resolve_dashboard look up by uuid to match.
  def to_param
    uuid
  end

  scope :pinned, -> { where(pinned: true) }

  # pin! — make this the island's single pinned dashboard. Clears any
  # sibling's pinned flag BEFORE setting this one so the partial unique
  # index ("one pinned per island") is never momentarily violated.
  def pin!
    transaction do
      island.metric_dashboards.where.not(id: id).update_all(pinned: false)
      update!(pinned: true)
    end
  end

  def unpin!
    update!(pinned: false)
  end

  # panels_count — small helper for the switcher row sub-text.
  def panels_count
    panels.is_a?(Array) ? panels.size : 0
  end

  # panel_card_key — the per-panel identifier the metrics-display
  # hide/reorder system matches on (a chart card's data-metric-key ==
  # the settings card's data-metric). Index-based so two panels sharing
  # a metric (host·CPU + web·CPU) stay distinct. Computed identically
  # in MetricDashboardData (chart grid) and MetricsController
  # (settings drawer) — MUST stay in lockstep. A structural edit
  # (add/remove panel) shifts indices and resets saved layout, which
  # is acceptable.
  def self.panel_card_key(index)
    "k#{index}"
  end

  private

  def ensure_uuid
    self.uuid ||= SecureRandom.uuid
  end

  # panels_well_formed — panels must be an Array (≤ MAX_PANELS) of
  # Hashes, each carrying the required keys, and pod panels carrying
  # the workload identity. Keeps a malformed POST (or a hand-edited
  # row) from rendering a broken grid.
  def panels_well_formed
    list = panels

    unless list.is_a?(Array)
      errors.add(:panels, "must be a list")
      return
    end

    if list.size > MAX_PANELS
      errors.add(:panels, "can have at most #{MAX_PANELS} panels")
    end

    list.each_with_index do |panel, i|
      unless panel.is_a?(Hash)
        errors.add(:panels, "panel #{i + 1} is malformed")
        next
      end

      missing = PANEL_KEYS.reject { |k| panel[k].to_s.present? }
      errors.add(:panels, "panel #{i + 1} is missing #{missing.join(", ")}") if missing.any?

      ct = panel["chart_type"].to_s
      errors.add(:panels, "panel #{i + 1} has an unknown chart type") if ct.present? && CHART_TYPES.exclude?(ct)

      next unless panel["scope_kind"].to_s == "pod"

      pod_missing = POD_PANEL_KEYS.reject { |k| panel[k].to_s.present? }
      errors.add(:panels, "pod panel #{i + 1} is missing #{pod_missing.join(", ")}") if pod_missing.any?
    end
  end
end
