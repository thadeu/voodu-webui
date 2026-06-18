# frozen_string_literal: true

require "digest"

# AlertEvent — one firing episode of a rule. Carries snapshots of the
# rule's display attributes (name, metric, target, threshold) taken
# at fire time, so the history list renders join-free and an edited
# or deleted-and-recreated rule can't rewrite past incidents.
class AlertEvent < ApplicationRecord
  belongs_to :alert_rule
  belongs_to :island

  STATES = %w[firing resolved].freeze

  validates :state, inclusion: {in: STATES}
  validates :started_at, :threshold, :rule_name, :metric_kind, :target_label,
    presence: true

  scope :firing, -> { where(state: "firing") }
  scope :resolved, -> { where(state: "resolved") }
  scope :recent, -> { order(started_at: :desc).limit(50) }

  def firing?
    state == "firing"
  end

  def format_value(value)
    AlertRule.format_metric_value(value, metric_kind)
  end

  # Unit derived from the snapshotted metric_kind (no dependency on
  # the live rule, which may be edited/gone).
  def unit
    AlertRule::PERCENT_KINDS.include?(metric_kind) ? "%" : "req/s"
  end

  # Episode length — open episodes measure against now.
  def duration_seconds
    ((resolved_at || Time.current) - started_at).to_i
  end

  # Opaque, stable deduplication key for outbound notifications (e.g.
  # a PagerDuty dedup_key). Derived from the episode's identity so
  # it's IDENTICAL across this event's firing→resolved transition —
  # letting a resolve close the incident its trigger opened — without
  # leaking the raw sequential DB id to the receiver.
  DEDUP_KEY_NAMESPACE = "voodu:alert_event"

  def to_dedup_key
    Digest::SHA256.hexdigest("#{DEDUP_KEY_NAMESPACE}:#{id}")
  end
end
