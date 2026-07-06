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
# Pinning: at most one dashboard per server is pinned. The pinned one is
# what /metrics opens to. `pin!` clears siblings in the same transaction
# (the partial unique index is the DB backstop).
class MetricDashboard < ApplicationRecord
  # M2: a dashboard belongs to the ORG, not a single server. Each panel
  # carries its own `server_id` (any server in the org), so one dashboard
  # mixes panels from different servers.
  belongs_to :org

  # Required keys every panel must carry (non-blank). `unit` is NOT here
  # — several metrics are legitimately unit-less (Requests, Net Rx/Tx,
  # error counts, Bytes Out all carry unit ""), so it only needs to
  # exist, not be present. Pod panels additionally need scope/name to
  # resolve the live replica; host panels don't.
  PANEL_KEYS = %w[scope_kind metric scale label color].freeze
  POD_PANEL_KEYS = %w[scope name].freeze

  # Log-count panels are a different beast: they count LOG LINES matching a
  # LogQuery filter, not warehouse samples — so no metric/scale. They carry
  # a workload identity (scope + name, like a pod panel) plus the filter
  # string in `query`, and render as a big-number tile (chart_type
  # "number") whose count spans the dashboard's global range. See
  # LogMetricData + Components::Metrics::NumberCard.
  LOG_PANEL_KEYS = %w[scope name query label color].freeze

  # Table panels render a generic DataTable from a registered DataSource
  # (DataTable::Registry) for one reader pod (scope/name) + a `view`. No
  # metric/scale — the source owns the (schema-less) columns.
  TABLE_PANEL_KEYS = %w[source scope name view label color].freeze

  # HTTP (external-API) table panels have no local reader pod — they carry the
  # request config (url + mapping) instead of scope/name. Same DataTable family
  # (source "http"), different required keys.
  HTTP_PANEL_KEYS = %w[source url label color].freeze

  # Allowed panel sources. "log" joins host/pod for log-count panels;
  # "table" is a DataSource-backed data table.
  SCOPE_KINDS = %w[host pod log table].freeze

  # Optional per-panel chart type. Absent → ChartCard defaults to "area".
  # "number" is the log-count tile (log panels only); "table" is the
  # DataTable panel (table panels only).
  CHART_TYPES = %w[area gauge_radial gauge_linear number table].freeze

  # Chart types a "table" (DataTable-family) panel may use. The hep3 source
  # can be a rows table OR a count viz (Number/Area/Radial/Linear); logs → table.
  TABLE_CHART_TYPES = %w[table number area gauge_radial gauge_linear].freeze

  # Bound the per-render fan-out — each panel is its own metric fetch.
  MAX_PANELS = 12

  validates :name, presence: true, length: {maximum: 128},
    uniqueness: {scope: :org_id}
  validate :panels_well_formed

  before_create :ensure_uuid

  # to_param — URLs use the opaque uuid, not the sequential integer id.
  # set_dashboard / resolve_dashboard look up by uuid to match.
  def to_param
    uuid
  end

  scope :pinned, -> { where(pinned: true) }

  # pin! — make this the org's single pinned dashboard. Clears any sibling's
  # pinned flag BEFORE setting this one so the partial unique index ("one
  # pinned per org") is never momentarily violated.
  def pin!
    transaction do
      org.metric_dashboards.where.not(id: id).update_all(pinned: false)
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

  # table_readers_for — distinct (scope, name) reader pods that table panels
  # POINTED AT THIS SERVER reference for `source`, across all the org's
  # dashboards. The Hep3 poller tails exactly these (demand-driven), so adding
  # a Table panel IS the poller's configuration — no separate readers setting.
  # Filters on panel["server_id"] now that dashboards are org-level.
  def self.table_readers_for(server, source:)
    server.org.metric_dashboards
      .flat_map { |dash| Array(dash.panels) }
      .select { |p| p.is_a?(Hash) && p["scope_kind"] == "table" && p["source"].to_s == source.to_s && p["server_id"].to_s == server.id.to_s }
      .map { |p| {scope: p["scope"].to_s, name: p["name"].to_s} }
      .reject { |r| r[:scope].empty? || r[:name].empty? }
      .uniq
  end

  private

  def ensure_uuid
    self.uuid ||= SecureRandom.uuid
  end

  # org_server_ids — the ids (as strings) of the servers in this dashboard's
  # org, for the per-panel server_id guard. Memoised per validation pass.
  def org_server_ids
    @org_server_ids ||= org&.servers&.pluck(:id)&.map(&:to_s) || []
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

      sk = panel["scope_kind"].to_s

      unless SCOPE_KINDS.include?(sk)
        errors.add(:panels, "panel #{i + 1} has an unknown source")
        next
      end

      # Each source carries its own required-key set: log → query,
      # table → source/view, everyone else → the metric layout.
      http = sk == "table" && panel["source"].to_s == "http"

      required =
        case sk
        when "log" then LOG_PANEL_KEYS
        when "table" then http ? HTTP_PANEL_KEYS : TABLE_PANEL_KEYS
        else PANEL_KEYS
        end
      missing = required.reject { |k| panel[k].to_s.present? }
      errors.add(:panels, "panel #{i + 1} is missing #{missing.join(", ")}") if missing.any?

      # server_id — which server this panel reads from. Required for every panel
      # that reads a server; an http (external-API) panel has no server. Guard:
      # the referenced server MUST belong to this dashboard's org — a forged id
      # for another org's server is rejected (anti cross-org injection).
      unless http
        iid = panel["server_id"].to_s

        if iid.blank?
          errors.add(:panels, "panel #{i + 1} is missing a server")
        elsif org_server_ids.exclude?(iid)
          errors.add(:panels, "panel #{i + 1} references a server outside this org")
        end
      end

      ct = panel["chart_type"].to_s
      errors.add(:panels, "panel #{i + 1} has an unknown chart type") if ct.present? && CHART_TYPES.exclude?(ct)
      # `number` is the count tile — for log panels OR a hep3/http count panel.
      number_ok = sk == "log" || (sk == "table" && %w[hep3 http].include?(panel["source"].to_s))
      errors.add(:panels, "panel #{i + 1}: the number type needs a log, hep3, or http source") if ct == "number" && !number_ok
      errors.add(:panels, "panel #{i + 1}: the table type is only for table panels") if ct == "table" && sk != "table"

      # A DataTable-family ("table") panel: the logs source only tabulates, but
      # the hep3 + http sources can ALSO be a count/timeseries chart.
      if sk == "table"
        allowed = %w[hep3 http].include?(panel["source"].to_s) ? TABLE_CHART_TYPES : %w[table]
        errors.add(:panels, "table panel #{i + 1} can't use the #{ct} chart type") unless allowed.include?(ct.presence || "table")
      end

      next unless sk == "pod"

      pod_missing = POD_PANEL_KEYS.reject { |k| panel[k].to_s.present? }
      errors.add(:panels, "pod panel #{i + 1} is missing #{pod_missing.join(", ")}") if pod_missing.any?
    end
  end
end
