# frozen_string_literal: true

require "test_helper"

class MetricDashboardTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  # Dashboards live at the ORG now (M2); every server panel carries its own
  # server_id (the server it reads from). @server is a server of @org.
  setup do
    @server = servers(:alpha)
    @org = @server.org
  end

  def host_panel
    {"scope_kind" => "host", "metric" => "cpu_percent", "scale" => "percent",
     "label" => "CPU", "color" => "var(--voodu-accent)", "unit" => "%", "server_id" => @server.id}
  end

  def log_panel
    {"scope_kind" => "log", "scope" => "fs", "name" => "fs", "server_id" => @server.id,
     "query" => "@message like /INVITE/", "agg" => "count",
     "label" => "fs · INVITE", "color" => "var(--voodu-orange)", "chart_type" => "number"}
  end

  test "panels round-trips as a Ruby Array (native json column)" do
    d = @org.metric_dashboards.create!(name: "a", panels: [host_panel])

    assert_kind_of Array, d.reload.panels
    assert_equal "cpu_percent", d.panels.first["metric"]
    assert_equal 1, d.panels_count
  end

  test "name is unique per org" do
    @org.metric_dashboards.create!(name: "dup", panels: [host_panel])
    dup = @org.metric_dashboards.new(name: "dup", panels: [host_panel])

    assert_not dup.valid?
    assert dup.errors[:name].present?
  end

  test "the same name is allowed in a different org" do
    @org.metric_dashboards.create!(name: "shared", panels: [host_panel])
    gamma = servers(:gamma)
    other = gamma.org.metric_dashboards.new(name: "shared",
      panels: [host_panel.merge("server_id" => gamma.id)])

    assert other.valid?, other.errors.full_messages.to_sentence
  end

  test "a panel with an empty unit is valid (Requests, Net Rx, errors, …)" do
    unitless = {"scope_kind" => "pod", "scope" => "api", "name" => "api", "kind" => "deployment",
                "metric" => "req_count", "scale" => "count", "server_id" => @server.id,
                "label" => "api · Requests", "color" => "var(--voodu-orange)", "unit" => ""}
    d = @org.metric_dashboards.new(name: "reqs", panels: [unitless])

    assert d.valid?, d.errors.full_messages.to_sentence
  end

  test "panels_well_formed rejects a pod panel missing its workload identity" do
    bad = @org.metric_dashboards.new(
      name: "x",
      panels: [{"scope_kind" => "pod", "metric" => "cpu_percent", "scale" => "percent",
                "label" => "l", "color" => "c", "unit" => "%"}]
    )

    assert_not bad.valid?
    assert bad.errors[:panels].present?
  end

  test "a log panel is valid with scope/name/query/label/color (no metric/scale)" do
    d = @org.metric_dashboards.new(name: "calls", panels: [log_panel])

    assert d.valid?, d.errors.full_messages.to_sentence
  end

  test "a log panel missing its query is rejected" do
    bad = log_panel.except("query")
    d = @org.metric_dashboards.new(name: "x", panels: [bad])

    assert_not d.valid?
    assert d.errors[:panels].present?
  end

  test "a log panel missing its workload identity is rejected" do
    bad = log_panel.except("name")
    d = @org.metric_dashboards.new(name: "x", panels: [bad])

    assert_not d.valid?
    assert d.errors[:panels].present?
  end

  test "the number chart type is rejected on a non-log panel" do
    bad = host_panel.merge("chart_type" => "number")
    d = @org.metric_dashboards.new(name: "x", panels: [bad])

    assert_not d.valid?
    assert d.errors[:panels].present?
  end

  test "an unknown scope_kind is rejected" do
    bad = host_panel.merge("scope_kind" => "wormhole")
    d = @org.metric_dashboards.new(name: "x", panels: [bad])

    assert_not d.valid?
    assert d.errors[:panels].present?
  end

  test "panels_well_formed rejects more than MAX_PANELS" do
    many = Array.new(MetricDashboard::MAX_PANELS + 1) { host_panel }
    d = @org.metric_dashboards.new(name: "big", panels: many)

    assert_not d.valid?
    assert bad_message(d), "expected a panels error"
  end

  test "pin! sets this one and unpins siblings — single pinned per org" do
    a = @org.metric_dashboards.create!(name: "a", panels: [host_panel])
    b = @org.metric_dashboards.create!(name: "b", panels: [host_panel])

    a.pin!
    assert a.reload.pinned

    b.pin!
    assert b.reload.pinned
    assert_not a.reload.pinned
    assert_equal 1, @org.metric_dashboards.pinned.count
  end

  test "unpin! clears the flag" do
    a = @org.metric_dashboards.create!(name: "a", panels: [host_panel], pinned: true)
    a.unpin!

    assert_not a.reload.pinned
  end

  test "destroyed with its org" do
    @org.metric_dashboards.create!(name: "a", panels: [host_panel])
    @org.servers.destroy_all # remove the org's servers so the org is deletable

    assert_difference("MetricDashboard.count", -1) { @org.destroy }
  end

  # ── Table panels (DataSource-backed) ──────────────────────────────

  def table_panel(**overrides)
    {"scope_kind" => "table", "chart_type" => "table", "source" => "hep3",
     "scope" => "fsw", "name" => "hep3-api", "view" => "messages", "server_id" => @server.id,
     "label" => "SIP", "color" => "var(--voodu-accent)"}.merge(overrides.transform_keys(&:to_s))
  end

  test "a table panel is valid with source/scope/name/view/label/color" do
    d = @org.metric_dashboards.new(name: "sip", panels: [table_panel])

    assert d.valid?, d.errors.full_messages.to_sentence
  end

  test "a table panel missing its source/view is rejected" do
    assert bad_message(@org.metric_dashboards.new(name: "a", panels: [table_panel(source: "")]))
    assert bad_message(@org.metric_dashboards.new(name: "b", panels: [table_panel(view: "")]))
  end

  test "the table chart type is rejected on a non-table panel" do
    panel = host_panel.merge("chart_type" => "table")

    assert bad_message(@org.metric_dashboards.new(name: "a", panels: [panel]))
  end

  test "a hep3 table panel may render as a count chart (Area/Radial/Linear)" do
    %w[area gauge_radial gauge_linear].each do |ct|
      d = @org.metric_dashboards.new(name: "a", panels: [table_panel(chart_type: ct)])

      assert d.valid?, "hep3 + #{ct} should be allowed: #{d.errors.full_messages}"
    end
  end

  test "a logs table panel must use the table chart type (logs only tabulate)" do
    assert bad_message(@org.metric_dashboards.new(name: "a", panels: [table_panel(source: "logs", chart_type: "area")]))
  end

  test "table_readers_for returns distinct hep3 readers across dashboards" do
    @org.metric_dashboards.create!(name: "a", panels: [table_panel(scope: "fsw", name: "hep3-api")])
    @org.metric_dashboards.create!(name: "b", panels: [
      table_panel(scope: "fsw", name: "hep3-api"),    # dup → collapses
      table_panel(scope: "ops", name: "sip"),         # distinct
      table_panel(scope: "x", name: "y", source: "other"), # different source → excluded
      host_panel                                       # non-table → ignored
    ])

    readers = MetricDashboard.table_readers_for(@server, source: "hep3")

    assert_equal [{scope: "fsw", name: "hep3-api"}, {scope: "ops", name: "sip"}].sort_by { |r| r[:name] },
      readers.sort_by { |r| r[:name] }
  end

  private

  def bad_message(record)
    record.valid?
    record.errors[:panels].present?
  end
end
