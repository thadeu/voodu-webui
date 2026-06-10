# frozen_string_literal: true

# AlertRule — one operator-defined threshold over the metrics
# warehouse. Four metric kinds map onto the warehouse series the
# /metrics page already charts:
#
#   cpu    → cpu_percent        (host via source=system, or pod)
#   memory → used ÷ total %     (host) / usage ÷ cgroup limit % (pod)
#   disk   → used ÷ total %     (host only — pods have no disk series)
#   req_s  → req_count ÷ bucket (ingress; per-deployment only, since
#                                ingress samples carry scope+name)
#
# Targets reuse the /metrics PodPicker addressing: host, or a
# (scope, resource_name) pair — NEVER a replica id, so rules survive
# pod churn (replica ids rotate on every restart, resource names
# don't).
#
# `firing`/`last_*` are evaluator-cached state for cheap rendering;
# the open AlertEvent row is the source of truth for the episode.
class AlertRule < ApplicationRecord
  belongs_to :island
  has_many :alert_events, dependent: :destroy

  METRIC_KINDS = %w[cpu memory disk req_s].freeze
  TARGET_KINDS = %w[host pod].freeze
  COMPARATORS  = %w[gte lte].freeze

  # Form-selectable sustained-for windows. Floor of 60s = 4 warehouse
  # buckets — enough samples that one noisy 15s tick can't fire alone.
  DURATIONS = [60, 120, 300, 600, 900, 1800].freeze

  # Percent-typed kinds share the 0–100 threshold bound; req_s is an
  # open-ended rate.
  PERCENT_KINDS = %w[cpu memory disk].freeze

  validates :name, presence: true, length: { maximum: 64 },
                   uniqueness: { scope: :island_id }
  validates :metric_kind, inclusion: { in: METRIC_KINDS }
  validates :target_kind, inclusion: { in: TARGET_KINDS }
  validates :comparator,  inclusion: { in: COMPARATORS }
  validates :duration_seconds, inclusion: { in: DURATIONS }
  validates :threshold, numericality: { greater_than: 0 }
  validates :threshold, numericality: { less_than_or_equal_to: 100 },
                        if: -> { PERCENT_KINDS.include?(metric_kind) }

  validates :target_scope, :target_name, presence: true,
                           if: -> { target_kind == "pod" }

  validate :disk_is_host_only
  validate :req_s_is_deployment_only

  scope :enabled, -> { where(enabled: true) }

  def self.firing_count_for(island_id)
    where(island_id: island_id, firing: true, enabled: true).count
  end

  # Starter rules — host-level safety net. No req/s default: request
  # rates are app-specific, there is no universal threshold worth
  # pre-installing. find_or_create_by! keys on (island, name) so the
  # button is idempotent — re-clicking never duplicates or resets
  # thresholds the operator has since tuned.
  DEFAULTS = [
    { name: "Host disk ≥ 85%",   metric_kind: "disk",   threshold: 85.0 },
    { name: "Host CPU ≥ 90%",    metric_kind: "cpu",    threshold: 90.0 },
    { name: "Host memory ≥ 90%", metric_kind: "memory", threshold: 90.0 }
  ].freeze

  def self.create_defaults!(island)
    DEFAULTS.map do |attrs|
      island.alert_rules.find_or_create_by!(name: attrs[:name]) do |rule|
        rule.metric_kind      = attrs[:metric_kind]
        rule.target_kind      = "host"
        rule.comparator       = "gte"
        rule.threshold        = attrs[:threshold]
        rule.duration_seconds = 300
      end
    end
  end

  def open_event
    alert_events.firing.first
  end

  def host_target?
    target_kind == "host"
  end

  def target_label
    host_target? ? "host #{island.name}" : "#{target_scope}/#{target_name}"
  end

  def unit
    PERCENT_KINDS.include?(metric_kind) ? "%" : "req/s"
  end

  def comparator_symbol
    comparator == "gte" ? "≥" : "≤"
  end

  def duration_label
    secs = duration_seconds
    secs >= 60 ? "#{secs / 60}m" : "#{secs}s"
  end

  # "92.3%" / "3.2 req/s" — the one value formatter every surface
  # (firing cards, rules table, history rows) shares, so a value
  # never renders with the unit glued differently in two places.
  def self.format_metric_value(value, metric_kind)
    return "—" if value.nil?

    rounded = value.to_f.round(1)
    rounded = rounded.to_i if rounded % 1 == 0
    suffix  = PERCENT_KINDS.include?(metric_kind) ? "%" : " req/s"

    "#{rounded}#{suffix}"
  end

  def format_value(value)
    self.class.format_metric_value(value, metric_kind)
  end

  # "≥ 85% for 5m" — the one condition string every surface renders.
  def condition_label
    "#{comparator_symbol} #{format_value(threshold)} for #{duration_label}"
  end

  # disable! — pause the rule AND close any open episode. A paused
  # rule must not keep the badge red: the operator explicitly said
  # "stop watching this", so the honest state is resolved-by-pause.
  def disable!
    transaction do
      open_event&.update!(state: "resolved", resolved_at: Time.current)
      update!(enabled: false, firing: false, firing_since: nil, last_status: nil)
    end
  end

  # Columns whose change invalidates an open episode: the episode
  # snapshotted the OLD condition (threshold/metric/target), and the
  # evaluator would otherwise resolve it later using the NEW metric's
  # series — closing a req/s episode with a CPU number, etc.
  EPISODE_INVALIDATING = %w[metric_kind target_kind target_scope target_name comparator threshold].freeze

  # clear_episode_on_change! — when a FIRING rule's condition is
  # edited, close the stale open episode and drop the firing flag.
  # The next evaluation tick re-opens a fresh episode against the new
  # condition if it still breaches. No-op when nothing condition-y
  # changed (e.g. a rename), so editing a firing rule's name doesn't
  # disrupt the live incident.
  def clear_episode_on_change!
    return unless firing?
    return if (saved_changes.keys & EPISODE_INVALIDATING).empty?

    transaction do
      open_event&.update!(state: "resolved", resolved_at: Time.current)
      update_columns(firing: false, firing_since: nil, last_status: nil, last_value: nil)
    end
  end

  private

  def disk_is_host_only
    return unless metric_kind == "disk" && target_kind == "pod"

    errors.add(:target_kind, "disk usage is only sampled at the host level")
  end

  def req_s_is_deployment_only
    return unless metric_kind == "req_s" && target_kind == "host"

    errors.add(:target_kind, "req/s is sampled per deployment — pick one")
  end
end
