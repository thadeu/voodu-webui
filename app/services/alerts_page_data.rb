# frozen_string_literal: true

# AlertsPageData — the one query bundle behind /alerts. Controller
# builds it once, the Index/Frame views consume it. Everything is
# primary-DB reads (rules + events + pod snapshot); the page renders
# instantly even with the controller offline.
#
# M3: alerts are ORG-level. Data (rules / events / destinations / targets) spans
# every server in the org; `island` is only the CURRENT server the /alerts URL
# is under — the default target when adding a rule and the "add to this server"
# context. A rule/event carries the server it targets/fired on.
class AlertsPageData
  # Cap on the windowed history list — a 30d window on a noisy org
  # could be thousands of rows; the timeline shows the most recent
  # MAX_HISTORY and notes the truncation.
  MAX_HISTORY = 200

  attr_reader :org, :island, :history_filter

  def initialize(org, island = nil, history_filter: AlertHistoryFilter.new)
    @org = org
    @island = island
    @history_filter = history_filter
  end

  def rules
    @rules ||= org.alert_rules.includes(:island).order(:name).to_a
  end

  # Open episodes, newest first — the red cards at the top.
  #
  # Scoped to enabled rules so a rule paused/deleted while an
  # evaluation tick was mid-flight (which can strand an open event on
  # a now-disabled rule) doesn't render a permanent red card the
  # sidebar badge — which already filters on enabled — wouldn't show.
  # includes(:alert_rule) kills the per-card N+1 from FiringCard
  # reading the live comparator.
  def firing_events
    @firing_events ||= org.alert_events.firing
      .joins(:alert_rule).where(alert_rules: {enabled: true})
      .includes(:alert_rule, :island)
      .order(started_at: :desc).to_a
  end

  # Closed episodes inside the active filter window, newest first,
  # capped at MAX_HISTORY. Firing ones live in their own tab.
  def history
    @history ||= history_scope.order(resolved_at: :desc).limit(MAX_HISTORY).to_a
  end

  # Count within the window — the "TIMELINE · N" header. Distinct from
  # history_count (the tab badge), which is the all-time total.
  def history_window_count
    @history_window_count ||= history_scope.count
  end

  def history_truncated?
    history_window_count > MAX_HISTORY
  end

  # Counts for the tab bar — cheap COUNT queries that DON'T load the
  # rows, so visiting the History tab doesn't pay to count firing
  # events and vice-versa. The row loaders above stay lazy, so only
  # the active tab's rows are ever materialised.
  def firing_count
    @firing_count ||= org.alert_events.firing
      .joins(:alert_rule).where(alert_rules: {enabled: true})
      .count
  end

  def rules_count
    @rules_count ||= org.alert_rules.count
  end

  def destinations
    @destinations ||= org.alert_destinations.order(:name).to_a
  end

  def destinations_count
    @destinations_count ||= org.alert_destinations.count
  end

  def history_count
    @history_count ||= org.alert_events.resolved.count
  end

  def rules?
    rules_count.positive?
  end

  # Form targets — distinct workloads across EVERY server in the org (M3), each
  # carrying its island_id + server name so the rule form's server-picker offers
  # a host + that server's pods. Same (scope, resource_name) addressing the
  # /metrics PodPicker uses; `kind` rides along so the form can keep req/s rules
  # on deployments (the only workloads ingress samples carry).
  def targets
    @targets ||= org.islands.order(:name).flat_map do |isl|
      isl.pods.distinct.pluck(:scope, :resource_name, :kind)
        .reject { |scope, name, _kind| scope.blank? || name.blank? }
        .map { |scope, name, kind| {island_id: isl.id, server: isl.name, scope: scope, name: name, kind: kind.to_s} }
    end.sort_by { |t| [t[:server], t[:scope], t[:name]] }
  end

  # servers — the org's servers, for the rule form's server-picker (host target
  # per server) + labelling which server each rule watches.
  def servers
    @servers ||= org.islands.order(:name).to_a
  end

  private

  def history_scope
    org.alert_events.resolved.where(resolved_at: history_filter.window.first..history_filter.window.last)
  end
end
