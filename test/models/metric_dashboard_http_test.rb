# frozen_string_literal: true

require "test_helper"

# An http (external-API) panel is a Table-family panel with source "http": it
# carries the request config (url) instead of a reader pod (scope/name). Pins
# the validation that lets it save without scope/name, requires a url, and
# allows the timeseries chart types.
class MetricDashboardHttpTest < ActiveSupport::TestCase
  fixtures :orgs, :servers

  setup do
    @server = servers(:alpha)
    @org = @server.org
  end

  def dashboard(panel)
    MetricDashboard.new(org: @org, name: "ext", panels: [panel])
  end

  def http_panel(**over)
    {
      "scope_kind" => "table", "source" => "http", "chart_type" => "table",
      "url" => "https://api.example.com/m", "label" => "Ext", "color" => "var(--voodu-cyan)",
      "mapping" => {"root" => "items", "columns" => []}
    }.merge(over.transform_keys(&:to_s))
  end

  test "an http panel is valid with a url and no scope/name" do
    assert dashboard(http_panel).valid?, -> { dashboard(http_panel).errors.full_messages.join("; ") }
  end

  test "an http panel without a url is invalid" do
    d = dashboard(http_panel("url" => ""))

    assert_not d.valid?
    assert_match(/missing url/i, d.errors.full_messages.join)
  end

  test "an http panel may use the timeseries chart types" do
    assert dashboard(http_panel("chart_type" => "area")).valid?
    assert dashboard(http_panel("chart_type" => "number")).valid?
    assert dashboard(http_panel("chart_type" => "gauge_radial")).valid?
  end

  test "an http panel rejects an unknown chart type" do
    assert_not dashboard(http_panel("chart_type" => "pie")).valid?
  end
end
