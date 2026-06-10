# frozen_string_literal: true

# AlertsPageData — the one query bundle behind /alerts. Controller
# builds it once, the Index/Frame views consume it. Everything is
# primary-DB reads (rules + events + pod snapshot); the page renders
# instantly even with the controller offline.
class AlertsPageData
  # Cap on the windowed history list — a 30d window on a noisy island
  # could be thousands of rows; the timeline shows the most recent
  # MAX_HISTORY and notes the truncation.
  MAX_HISTORY = 200

  attr_reader :island, :history_filter

  def initialize(island, history_filter: AlertHistoryFilter.new)
    @island         = island
    @history_filter = history_filter
  end

  def rules
    @rules ||= island.alert_rules.order(:name).to_a
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
    @firing_events ||= island.alert_events.firing
                             .joins(:alert_rule).where(alert_rules: { enabled: true })
                             .includes(:alert_rule)
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
    @firing_count ||= island.alert_events.firing
                            .joins(:alert_rule).where(alert_rules: { enabled: true })
                            .count
  end

  def rules_count
    @rules_count ||= island.alert_rules.count
  end

  def history_count
    @history_count ||= island.alert_events.resolved.count
  end

  def rules?
    rules_count.positive?
  end

  # Form targets — distinct workloads from the state-sync pod
  # snapshot, the same (scope, resource_name) addressing the /metrics
  # PodPicker uses. `kind` rides along so the form can keep req/s
  # rules on deployments (the only workloads ingress samples carry).
  def targets
    @targets ||= island.pods
                       .distinct
                       .pluck(:scope, :resource_name, :kind)
                       .reject { |scope, name, _kind| scope.blank? || name.blank? }
                       .sort
                       .map { |scope, name, kind| { scope: scope, name: name, kind: kind.to_s } }
  end

  private

  def history_scope
    island.alert_events.resolved.where(resolved_at: history_filter.window.first..history_filter.window.last)
  end
end
