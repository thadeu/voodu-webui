# frozen_string_literal: true

require "test_helper"

# AlertEvaluator core suite. Seeds the metrics warehouse directly —
# only tenant_id/source/ts_iso/payload are written; ts_epoch / scope /
# name / pod are SQLite generated columns (same seeding approach as
# MetricsDigestServiceTest).
#
# All tests freeze time at a 15s-aligned instant so seeded sample
# epochs land exactly on warehouse bucket boundaries.
class AlertEvaluatorTest < ActiveSupport::TestCase
  fixtures :islands

  NOW = Time.utc(2026, 6, 9, 12, 0, 0)

  setup do
    MetricSample.delete_all
    @island = islands(:alpha)
    @broadcasts = []
    @stubs = []
    # Local capture on purpose: define_method rebinds `self` (and thus
    # ivars) to the receiver — `@broadcasts` inside the block would be
    # a nil ivar on AlertsLive, and the `<<` would explode inside the
    # evaluator's rescue. Locals close over lexically.
    captured = @broadcasts
    stub_class_method(AlertsLive, :broadcast) { |island| captured << island.id }
    travel_to NOW
  end

  teardown do
    travel_back
    restore_stubs
    MetricSample.delete_all
  end

  # ---- firing --------------------------------------------------------

  test "fires when every bucket in the duration window breaches" do
    rule = host_cpu_rule(threshold: 90, duration: 120)
    seed_system_range(cpu_percent: 95.0)

    assert_equal 1, AlertEvaluator.run(@island)

    rule.reload
    assert rule.firing
    assert_equal "firing", rule.last_status
    assert_in_delta 95.0, rule.last_value

    event = rule.open_event
    assert_not_nil event
    assert_in_delta 95.0, event.peak_value
    assert_equal rule.target_label, event.target_label
    assert_equal [@island.id], @broadcasts
  end

  test "does not fire when one mid-window bucket dips under" do
    rule = host_cpu_rule(threshold: 90, duration: 120)
    seed_system_range(cpu_percent: 95.0) do |epoch|
      epoch == NOW.to_i - 60 ? 50.0 : 95.0
    end

    assert_equal 0, AlertEvaluator.run(@island)

    rule.reload
    assert_not rule.firing
    assert_equal "ok", rule.last_status
    assert_empty @broadcasts
  end

  test "lte comparator fires when values sit under the threshold" do
    rule = host_cpu_rule(threshold: 10, duration: 120, comparator: "lte")
    seed_system_range(cpu_percent: 2.0)

    AlertEvaluator.run(@island)

    assert rule.reload.firing
  end

  # ---- resolving -----------------------------------------------------

  test "resolves only after three consecutive clean tail buckets" do
    rule = host_cpu_rule(threshold: 90, duration: 120)
    seed_system_range(cpu_percent: 95.0, from: NOW.to_i - 165, to: NOW.to_i - 60)
    AlertEvaluator.run(@island)
    assert rule.reload.firing

    # One clean bucket — not enough.
    seed_system(NOW.to_i - 45, cpu_percent: 5.0)
    AlertEvaluator.run(@island)
    assert rule.reload.firing, "one clean bucket must not resolve"

    # Two more clean buckets → 3-clean tail → resolve.
    seed_system(NOW.to_i - 30, cpu_percent: 5.0)
    seed_system(NOW.to_i - 15, cpu_percent: 5.0)
    assert_equal 1, AlertEvaluator.run(@island)

    rule.reload
    assert_not rule.firing
    assert_equal "ok", rule.last_status
    assert_equal "resolved", rule.alert_events.order(:id).last.state
    assert_not_nil rule.alert_events.order(:id).last.resolved_at
  end

  test "keeps peak value fresh while the episode stays open" do
    rule = host_cpu_rule(threshold: 90, duration: 120)
    seed_system_range(cpu_percent: 95.0)
    AlertEvaluator.run(@island)

    travel 15.seconds
    seed_system(NOW.to_i, cpu_percent: 99.5)
    AlertEvaluator.run(@island)

    event = rule.reload.open_event
    assert_in_delta 99.5, event.peak_value
    assert_in_delta 99.5, event.last_value
  end

  # ---- missing / stale data ------------------------------------------

  test "no data never fires" do
    rule = host_cpu_rule(threshold: 90, duration: 120)

    assert_equal 0, AlertEvaluator.run(@island)

    rule.reload
    assert_not rule.firing
    assert_equal "no_data", rule.last_status
  end

  test "stale series holds a firing alert instead of resolving it" do
    rule = host_cpu_rule(threshold: 90, duration: 120)
    seed_system_range(cpu_percent: 95.0)
    AlertEvaluator.run(@island)
    assert rule.reload.firing

    travel 10.minutes

    assert_equal 0, AlertEvaluator.run(@island)

    rule.reload
    assert rule.firing, "stale data must not resolve a firing alert"
    assert_equal "stale", rule.last_status
    assert_equal "firing", rule.open_event.state
    assert_in_delta 95.0, rule.last_value, 0.001, "stale firing rule keeps its last known value"
  end

  test "fire! is refused when the rule was disabled mid-tick" do
    rule = host_cpu_rule(threshold: 90, duration: 120)
    seed_system_range(cpu_percent: 95.0)

    # Simulate the operator pausing the rule in the web process after
    # run() snapshotted the enabled set: the in-memory record still
    # looks enabled, but the row is now disabled.
    AlertRule.where(id: rule.id).update_all(enabled: false)

    AlertEvaluator.new(@island).send(:evaluate, rule)

    rule.reload
    assert_not rule.firing, "must not fire a rule disabled mid-tick"
    assert_equal 0, rule.alert_events.firing.count
  end

  test "sparse coverage below the gate reads as no_data" do
    rule = host_cpu_rule(threshold: 90, duration: 120)
    # only 3 of the expected 8 buckets exist (gate is ceil(8 * 0.6) = 5)
    seed_system(NOW.to_i - 45, cpu_percent: 95.0)
    seed_system(NOW.to_i - 30, cpu_percent: 95.0)
    seed_system(NOW.to_i - 15, cpu_percent: 95.0)

    AlertEvaluator.run(@island)

    rule.reload
    assert_not rule.firing
    assert_equal "no_data", rule.last_status
  end

  # ---- metric math ---------------------------------------------------

  test "host memory percent derives from warehouse total fallback" do
    rule = make_rule(name: "mem", metric_kind: "memory", threshold: 85, duration: 120)
    seed_system_range(mem_used_bytes: 9_000_000_000, mem_total_bytes: 10_000_000_000)

    AlertEvaluator.run(@island)

    rule.reload
    assert rule.firing
    assert_in_delta 90.0, rule.last_value
  end

  test "host disk percent fires against warehouse totals" do
    rule = make_rule(name: "disk", metric_kind: "disk", threshold: 85, duration: 120)
    seed_system_range(disk_used_bytes: 88_000_000_000, disk_total_bytes: 100_000_000_000)

    AlertEvaluator.run(@island)

    rule.reload
    assert rule.firing
    assert_in_delta 88.0, rule.last_value
  end

  test "pod memory with kernel-max sentinel limit reads as no_data" do
    rule = make_rule(
      name: "pod mem", metric_kind: "memory", threshold: 85, duration: 120,
      target_kind: "pod", target_scope: "clowk", target_name: "web"
    )
    seed_pod_range(mem_usage_bytes: 500_000_000, mem_limit_bytes: 2_199_023_255_552)

    AlertEvaluator.run(@island)

    rule.reload
    assert_not rule.firing
    assert_equal "no_data", rule.last_status
  end

  test "pod memory percent uses the cgroup limit" do
    rule = make_rule(
      name: "pod mem", metric_kind: "memory", threshold: 85, duration: 120,
      target_kind: "pod", target_scope: "clowk", target_name: "web"
    )
    seed_pod_range(mem_usage_bytes: 900_000_000, mem_limit_bytes: 1_000_000_000)

    AlertEvaluator.run(@island)

    rule.reload
    assert rule.firing
    assert_in_delta 90.0, rule.last_value
  end

  test "req_s converts bucket counts into a per-second rate" do
    rule = make_rule(
      name: "reqs", metric_kind: "req_s", threshold: 10, duration: 120,
      target_kind: "pod", target_scope: "clowk", target_name: "web"
    )
    seed_ingress_range(req_count: 300) # 300 per 15s bucket = 20 req/s

    AlertEvaluator.run(@island)

    rule.reload
    assert rule.firing
    assert_in_delta 20.0, rule.last_value
  end

  # ---- robustness ----------------------------------------------------

  test "concurrent double-fire is absorbed by the partial unique index" do
    rule = host_cpu_rule(threshold: 90, duration: 120)
    seed_system_range(cpu_percent: 95.0)

    # Simulate a racing tick that already opened the episode but whose
    # rule-flag write hasn't been seen by this process yet.
    rule.alert_events.create!(
      island: @island, state: "firing", started_at: 1.minute.ago,
      threshold: 90, rule_name: rule.name, metric_kind: "cpu",
      target_label: rule.target_label
    )

    AlertEvaluator.run(@island)

    rule.reload
    assert rule.firing
    assert_equal 1, rule.alert_events.count
  end

  test "one broken rule does not kill the island tick" do
    bad = host_cpu_rule(threshold: 90, duration: 120, name: "bad")
    bad.update_columns(metric_kind: "bogus") # bypass validation on purpose
    good = host_cpu_rule(threshold: 90, duration: 120, name: "good")
    seed_system_range(cpu_percent: 95.0)

    assert_nothing_raised { AlertEvaluator.run(@island) }

    assert good.reload.firing
    assert_equal "no_data", bad.reload.last_status
  end

  test "disabled rules are skipped" do
    rule = host_cpu_rule(threshold: 90, duration: 120)
    rule.update!(enabled: false)
    seed_system_range(cpu_percent: 95.0)

    assert_equal 0, AlertEvaluator.run(@island)
    assert_not rule.reload.firing
  end

  private

  def host_cpu_rule(threshold:, duration:, comparator: "gte", name: "cpu")
    make_rule(name: name, metric_kind: "cpu", threshold: threshold,
              duration: duration, comparator: comparator)
  end

  def make_rule(name:, metric_kind:, threshold:, duration:, comparator: "gte",
                target_kind: "host", target_scope: nil, target_name: nil)
    @island.alert_rules.create!(
      name: name, metric_kind: metric_kind, target_kind: target_kind,
      target_scope: target_scope, target_name: target_name,
      comparator: comparator, threshold: threshold, duration_seconds: duration
    )
  end

  # Seed one system sample per 15s bucket across [from, to]. The block
  # (when given) maps epoch → cpu value, letting a test dip one bucket.
  def seed_system_range(from: NOW.to_i - 165, to: NOW.to_i - 15, **metrics, &block)
    (from..to).step(15) do |epoch|
      row = metrics.dup
      row[:cpu_percent] = block.call(epoch) if block && metrics.key?(:cpu_percent)
      seed_system(epoch, **row)
    end
  end

  def seed_system(epoch, **metrics)
    insert_sample(epoch, source: "system", payload: metrics)
  end

  def seed_pod_range(from: NOW.to_i - 165, to: NOW.to_i - 15, **metrics)
    (from..to).step(15) do |epoch|
      insert_sample(
        epoch, source: "pod",
        payload: metrics.merge(scope: "clowk", name: "web", container: "clowk-x-web.a1b2")
      )
    end
  end

  def seed_ingress_range(from: NOW.to_i - 165, to: NOW.to_i - 15, **metrics)
    (from..to).step(15) do |epoch|
      insert_sample(epoch, source: "ingress", payload: metrics.merge(scope: "clowk", name: "web"))
    end
  end

  def insert_sample(epoch, source:, payload:)
    ts = Time.at(epoch).utc.iso8601
    MetricSample.insert!(
      {
        tenant_id: @island.id,
        source:    source,
        ts_iso:    ts,
        payload:   payload.merge(ts: ts, source: source).to_json
      }
    )
  end

  # UnboundMethod-based stub/restore — same rationale as
  # MetricsDigestServiceTest (`def self.x` lives in the singleton
  # slot; bare remove_method would nuke the original).
  def stub_class_method(klass, name, &block)
    original = klass.singleton_class.instance_method(name)
    klass.singleton_class.define_method(name, &block)
    @stubs << [klass, name, original]
  end

  def restore_stubs
    while (entry = @stubs&.pop)
      klass, name, original = entry
      klass.singleton_class.define_method(name, original)
    end
  end
end
