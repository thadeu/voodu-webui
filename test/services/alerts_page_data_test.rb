# frozen_string_literal: true

require "test_helper"

class AlertsPageDataTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  NOW = Time.utc(2026, 6, 10, 12, 0, 0)

  setup do
    @server = servers(:alpha)
    @rule = @server.alert_rules.create!(
      name: "cpu", metric_kind: "cpu", target_kind: "host",
      comparator: "gte", threshold: 90, duration_seconds: 300
    )
    travel_to NOW
  end

  teardown { travel_back }

  test "history is scoped to the filter window, newest first" do
    resolved_at([2.hours, 2.days, 10.days])

    data = AlertsPageData.new(@server.org, @server, history_filter: AlertHistoryFilter.new(range: "7d"))

    assert_equal 2, data.history.size, "10d-old event is outside the 7d window"
    assert_equal 2, data.history_window_count
    assert_operator data.history.first.resolved_at, :>, data.history.last.resolved_at
  end

  test "24h window excludes a 2-day-old event" do
    resolved_at([1.hour, 2.days])

    data = AlertsPageData.new(@server.org, @server, history_filter: AlertHistoryFilter.new(range: "24h"))

    assert_equal 1, data.history.size
  end

  test "history_count is the all-time total, independent of the window" do
    resolved_at([1.hour, 2.days, 40.days])

    data = AlertsPageData.new(@server.org, @server, history_filter: AlertHistoryFilter.new(range: "24h"))

    assert_equal 1, data.history.size, "window holds only the recent one"
    assert_equal 3, data.history_count, "tab badge counts everything"
  end

  test "truncation flag trips past MAX_HISTORY" do
    stub_const(AlertsPageData, :MAX_HISTORY, 2) do
      resolved_at([1.hour, 2.hours, 3.hours])

      data = AlertsPageData.new(@server.org, @server, history_filter: AlertHistoryFilter.new(range: "24h"))

      assert_equal 2, data.history.size
      assert_equal 3, data.history_window_count
      assert data.history_truncated?
    end
  end

  private

  def resolved_at(ages)
    ages.each do |age|
      ts = NOW - age
      @server.alert_events.create!(
        alert_rule: @rule, state: "resolved", started_at: ts - 60, resolved_at: ts,
        threshold: 90, rule_name: @rule.name, metric_kind: "cpu", target_label: @rule.target_label
      )
    end
  end

  def stub_const(mod, name, value)
    original = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, original)
  end
end
