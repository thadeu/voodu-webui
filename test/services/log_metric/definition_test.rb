# frozen_string_literal: true

require "test_helper"

class LogMetric::DefinitionTest < ActiveSupport::TestCase
  fixtures :orgs, :islands

  setup do
    @island = islands(:alpha)
    @org = @island.org
  end

  def log_panel(scope: "fs", name: "fs", query: "@message like /INVITE/", label: "fs · INVITE")
    {"scope_kind" => "log", "scope" => scope, "name" => name, "query" => query,
     "island_id" => @island.id,
     "label" => label, "color" => "var(--voodu-orange)", "chart_type" => "number"}
  end

  def metric_panel
    {"scope_kind" => "host", "metric" => "cpu_percent", "scale" => "percent",
     "label" => "CPU", "color" => "var(--voodu-accent)", "unit" => "%", "island_id" => @island.id}
  end

  test "key_for is stable and varies with each identity field" do
    base = LogMetric::Definition.key_for(scope: "fs", name: "fs", query: "@message like /INVITE/")

    assert_equal base, LogMetric::Definition.key_for(scope: "fs", name: "fs", query: "@message like /INVITE/")
    assert_match(/\Alm:[0-9a-f]{16}\z/, base)
    assert_not_equal base, LogMetric::Definition.key_for(scope: "fs", name: "fs", query: "@message like /BYE/")
    assert_not_equal base, LogMetric::Definition.key_for(scope: "other", name: "fs", query: "@message like /INVITE/")
  end

  test "all_for collects distinct log panels across dashboards, skipping non-log + malformed" do
    @org.metric_dashboards.create!(name: "a", panels: [metric_panel, log_panel])
    @org.metric_dashboards.create!(name: "b", panels: [
      log_panel,
      log_panel(query: "@message like /480/", label: "fs · Failed")
    ])

    defs = LogMetric::Definition.all_for(@island)

    assert_equal 2, defs.size, "the duplicate INVITE filter (a + b) collapses to one"
    queries = defs.map(&:query).sort

    assert_equal ["@message like /480/", "@message like /INVITE/"], queries
  end

  test "predicate compiles the LogQuery and matches a record" do
    d = LogMetric::Definition.new(scope: "fs", name: "fs", query: "@message like /INVITE/")

    assert d.predicate.call({msg: "got INVITE here", raw: "got INVITE here", level: "", stream: ""})
    assert_not d.predicate.call({msg: "200 OK", raw: "200 OK", level: "", stream: ""})
  end

  test "agg defaults to count when the query has no agg stage" do
    d = LogMetric::Definition.new(scope: "fs", name: "fs", query: "@message like /INVITE/")

    assert_equal :count, d.agg
  end

  test "agg reflects the | <agg> suffix" do
    d = LogMetric::Definition.new(scope: "fs", name: "fs", query: "@message like /Hangup/ | avg")

    assert_equal :avg, d.agg
  end

  test "the agg suffix is part of the key (different agg → different series)" do
    base = LogMetric::Definition.new(scope: "fs", name: "fs", query: "@message like /h/").key
    avged = LogMetric::Definition.new(scope: "fs", name: "fs", query: "@message like /h/ | avg").key

    assert_not_equal base, avged
  end

  test "log_count is an allowed warehouse metric and aggregates with SUM" do
    assert_includes MetricsWarehouse::ALLOWED_METRICS, "log_count"
    assert_equal "SUM", MetricsWarehouse::METRIC_AGGREGATIONS["log_count"]
  end
end
