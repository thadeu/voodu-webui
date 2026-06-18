# frozen_string_literal: true

require "test_helper"

class MetricDashboardTest < ActiveSupport::TestCase
  fixtures :islands

  setup { @island = islands(:alpha) }

  def host_panel
    {"scope_kind" => "host", "metric" => "cpu_percent", "scale" => "percent",
     "label" => "CPU", "color" => "var(--voodu-accent)", "unit" => "%"}
  end

  test "panels round-trips as a Ruby Array (native json column)" do
    d = @island.metric_dashboards.create!(name: "a", panels: [host_panel])

    assert_kind_of Array, d.reload.panels
    assert_equal "cpu_percent", d.panels.first["metric"]
    assert_equal 1, d.panels_count
  end

  test "name is unique per island" do
    @island.metric_dashboards.create!(name: "dup", panels: [host_panel])
    dup = @island.metric_dashboards.new(name: "dup", panels: [host_panel])

    assert_not dup.valid?
    assert dup.errors[:name].present?
  end

  test "the same name is allowed on a different island" do
    @island.metric_dashboards.create!(name: "shared", panels: [host_panel])
    other = islands(:beta).metric_dashboards.new(name: "shared", panels: [host_panel])

    assert other.valid?
  end

  test "a panel with an empty unit is valid (Requests, Net Rx, errors, …)" do
    unitless = {"scope_kind" => "pod", "scope" => "api", "name" => "api", "kind" => "deployment",
                "metric" => "req_count", "scale" => "count",
                "label" => "api · Requests", "color" => "var(--voodu-orange)", "unit" => ""}
    d = @island.metric_dashboards.new(name: "reqs", panels: [unitless])

    assert d.valid?, d.errors.full_messages.to_sentence
  end

  test "panels_well_formed rejects a pod panel missing its workload identity" do
    bad = @island.metric_dashboards.new(
      name: "x",
      panels: [{"scope_kind" => "pod", "metric" => "cpu_percent", "scale" => "percent",
                "label" => "l", "color" => "c", "unit" => "%"}]
    )

    assert_not bad.valid?
    assert bad.errors[:panels].present?
  end

  test "panels_well_formed rejects more than MAX_PANELS" do
    many = Array.new(MetricDashboard::MAX_PANELS + 1) { host_panel }
    d = @island.metric_dashboards.new(name: "big", panels: many)

    assert_not d.valid?
    assert bad_message(d), "expected a panels error"
  end

  test "pin! sets this one and unpins siblings — single pinned per island" do
    a = @island.metric_dashboards.create!(name: "a", panels: [host_panel])
    b = @island.metric_dashboards.create!(name: "b", panels: [host_panel])

    a.pin!
    assert a.reload.pinned

    b.pin!
    assert b.reload.pinned
    assert_not a.reload.pinned
    assert_equal 1, @island.metric_dashboards.pinned.count
  end

  test "unpin! clears the flag" do
    a = @island.metric_dashboards.create!(name: "a", panels: [host_panel], pinned: true)
    a.unpin!

    assert_not a.reload.pinned
  end

  test "destroyed with its island" do
    @island.metric_dashboards.create!(name: "a", panels: [host_panel])

    assert_difference("MetricDashboard.count", -1) { @island.destroy }
  end

  private

  def bad_message(record)
    record.valid?
    record.errors[:panels].present?
  end
end
