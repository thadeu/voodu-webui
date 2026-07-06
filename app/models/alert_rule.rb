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
  # org — the owner (M3). island — the TARGET server this rule monitors (∈ org).
  # A rule is org-level (listed on the org's /alerts) but watches exactly one
  # server, so `island` stays the addressing target the evaluator runs against.
  belongs_to :org
  belongs_to :island
  has_many :alert_events, dependent: :destroy
  has_many :alert_rule_destinations, dependent: :destroy
  has_many :alert_destinations, through: :alert_rule_destinations

  METRIC_KINDS = %w[cpu memory disk req_s].freeze
  TARGET_KINDS = %w[host pod].freeze
  COMPARATORS = %w[gte lte].freeze

  # Form-selectable sustained-for windows. Floor of 60s = 4 warehouse
  # buckets — enough samples that one noisy 15s tick can't fire alone.
  DURATIONS = [60, 120, 300, 600, 900, 1800].freeze

  # Percent-typed kinds share the 0–100 threshold bound; req_s is an
  # open-ended rate.
  PERCENT_KINDS = %w[cpu memory disk].freeze

  validates :name, presence: true, length: {maximum: 64},
    uniqueness: {scope: :island_id}
  validates :metric_kind, inclusion: {in: METRIC_KINDS}
  validates :target_kind, inclusion: {in: TARGET_KINDS}
  validates :comparator, inclusion: {in: COMPARATORS}
  validates :duration_seconds, inclusion: {in: DURATIONS}
  validates :threshold, numericality: {greater_than: 0}
  validates :threshold, numericality: {less_than_or_equal_to: 100},
    if: -> { PERCENT_KINDS.include?(metric_kind) }

  validates :target_scope, :target_name, presence: true,
    if: -> { target_kind == "pod" }

  # org is canonically the TARGET server's org — a rule can't watch a server in
  # a different org (target_island_in_org enforces it). Derive it so building a
  # rule off `island.alert_rules` (or any island) never needs org spelled out;
  # `||=` leaves an explicitly-set (possibly forged) org for the guard to reject.
  before_validation :derive_org_from_island

  validate :disk_is_host_only
  validate :req_s_is_deployment_only
  validate :target_island_in_org

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
    {name: "Host disk ≥ 85%", metric_kind: "disk", threshold: 85.0},
    {name: "Host CPU ≥ 90%", metric_kind: "cpu", threshold: 90.0},
    {name: "Host memory ≥ 90%", metric_kind: "memory", threshold: 90.0}
  ].freeze

  def self.create_defaults!(island)
    DEFAULTS.map do |attrs|
      island.alert_rules.find_or_create_by!(name: attrs[:name]) do |rule|
        # org — the rule is owned by the target server's org (M3).
        rule.org = island.org
        rule.metric_kind = attrs[:metric_kind]
        rule.target_kind = "host"
        rule.comparator = "gte"
        rule.threshold = attrs[:threshold]
        rule.duration_seconds = 300
      end
    end
  end

  def open_event
    alert_events.firing.first
  end

  # Destinations to notify for a fire/resolve `transition`. An empty
  # explicit selection means "all" — the same convention the logs
  # PodScopePicker uses (no rows checked = all pods). So a rule with
  # no join rows fans out to every enabled island destination that
  # wants this transition; a rule with rows uses exactly that subset
  # (still filtered by enabled + the destination's firing/resolved
  # toggle).
  # destinations_for — the enabled destinations to notify for `transition`. An
  # empty selection means DON'T SEND (the honest default) — a rule notifies only
  # the destinations explicitly wired to it, never a surprise fan-out. Checking
  # "Select all" is how the operator opts into every destination.
  def destinations_for(transition)
    alert_destinations.select { |d| d.enabled? && d.notifies?(transition) }
  end

  # Params to deep-link this rule's target into /metrics so the
  # operator lands straight on the relevant chart grid. Host rules go
  # to the host scope; pod rules resolve a current replica's container
  # name (the metrics page keys pod scope by container, not by
  # deployment). A deployment with no live replica falls back to the
  # host grid rather than a blank pod view.
  def metrics_link_params
    return {scope_kind: "host"} if host_target?

    container = island.pods
      .where(scope: target_scope, resource_name: target_name)
      .order(:container_name).limit(1).pick(:container_name)

    container ? {scope_kind: "pod", scope_id: container} : {scope_kind: "host"}
  end

  def host_target?
    target_kind == "host"
  end

  # target_label — human "what this watches". Both shapes name the SERVER (M3:
  # rules are org-level, so "web/web" alone is ambiguous across servers). Host →
  # "host <server>"; pod → "<server> · <scope>/<name>". Snapshotted onto events
  # at fire time, so history says which server fired.
  def target_label
    host_target? ? "host #{island.name}" : "#{island.name} · #{target_scope}/#{target_name}"
  end

  def unit
    PERCENT_KINDS.include?(metric_kind) ? "%" : "req/s"
  end

  def comparator_symbol
    (comparator == "gte") ? "≥" : "≤"
  end

  def duration_label
    secs = duration_seconds
    (secs >= 60) ? "#{secs / 60}m" : "#{secs}s"
  end

  # "92.3" — the bare rounded number (1 decimal, trailing .0 trimmed),
  # no unit. Shared by format_metric_value and the webhook template
  # tokens so a value never renders with 14 decimals of float noise.
  def self.format_metric_number(value)
    return "" if value.nil?

    rounded = value.to_f.round(1)
    (rounded % 1 == 0) ? rounded.to_i.to_s : rounded.to_s
  end

  # "92.3%" / "3.2 req/s" — the one value formatter every surface
  # (firing cards, rules table, history rows) shares, so a value
  # never renders with the unit glued differently in two places.
  def self.format_metric_value(value, metric_kind)
    return "—" if value.nil?

    suffix = PERCENT_KINDS.include?(metric_kind) ? "%" : " req/s"

    "#{format_metric_number(value)}#{suffix}"
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

  def derive_org_from_island
    self.org ||= island&.org
  end

  # target_island_in_org — the monitored server MUST belong to this rule's org
  # (M3 anti cross-org injection): a rule can never watch a server outside the
  # org it's listed under, so a forged island_id for another org's server is
  # rejected at save (mirrors the dashboard panel island_id guard).
  def target_island_in_org
    return if island_id.blank? || org_id.blank?
    return if island&.org_id == org_id

    errors.add(:island, "must be a server in this org")
  end

  def disk_is_host_only
    return unless metric_kind == "disk" && target_kind == "pod"

    errors.add(:target_kind, "disk usage is only sampled at the host level")
  end

  def req_s_is_deployment_only
    return unless metric_kind == "req_s" && target_kind == "host"

    errors.add(:target_kind, "req/s is sampled per deployment — pick one")
  end
end
