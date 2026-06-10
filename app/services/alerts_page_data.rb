# frozen_string_literal: true

# AlertsPageData — the one query bundle behind /alerts. Controller
# builds it once, the Index/Frame views consume it. Everything is
# primary-DB reads (rules + events + pod snapshot); the page renders
# instantly even with the controller offline.
class AlertsPageData
  attr_reader :island

  def initialize(island)
    @island = island
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

  # Closed episodes for the history list. Firing ones live in their
  # own section; mixing them in here would double-render.
  def history
    @history ||= island.alert_events.resolved.recent.to_a
  end

  def firing_count
    firing_events.size
  end

  def rules?
    rules.any?
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
end
