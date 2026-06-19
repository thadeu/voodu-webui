# frozen_string_literal: true

require "test_helper"

# Covers the metrics range picker: the preset pills, the custom popover,
# param passthrough, and the preset-vs-custom active state. Régua: each
# assertion breaks if the behavior is inverted (wrong active state, a
# dropped param, a missing custom field).
class Components::Metrics::RangePickerTest < ActiveSupport::TestCase
  # metrics_path is tenant-scoped (/:tenant_key/metrics), so the picker
  # needs a view context whose request carries a tenant_key for the route
  # helper to resolve. Build one once.
  setup do
    controller = ApplicationController.new
    req = ActionDispatch::TestRequest.create
    req.path_parameters = {tenant_key: "ABC123", controller: "metrics", action: "index"}
    controller.request = req
    controller.response = ActionDispatch::TestResponse.new
    @view = controller.view_context
  end

  def render_picker(**opts)
    base = {range: "1h"}

    Components::Metrics::RangePicker.new(**base.merge(opts)).render_in(@view)
  end

  test "renders every preset pill as a form button wired to selectRange" do
    html = render_picker

    Components::Metrics::RangePicker::RANGES.each { |r| assert_includes html, ">#{r}<" }
    assert_includes html, "time-range-filter#selectRange"
    assert_includes html, 'method="get"'
    assert_includes html, "time-range-filter#normalizeDates"
  end

  test "the active preset gets the accent chrome; the others stay muted" do
    html = render_picker(range: "6h")

    assert_includes html, 'bg-voodu-accent-dim text-voodu-accent-2">6h</button>'
    assert_includes html, 'text-voodu-text-2 hover:bg-voodu-surface-2">1h</button>'
    assert_includes html, 'aria-selected="true" data-time-range-filter-target="preset" data-range="6h"'
  end

  test "custom mode lights the custom chip and no preset is active" do
    html = render_picker(range: "1h", custom: true)

    assert_includes html, 'data-range="custom"'
    assert_includes html, 'aria-selected="false"', "no preset is active in custom mode"
    assert_not_includes html, 'aria-selected="true"'
    assert_includes html, 'name="range" value="custom"'
  end

  test "extra params ride along as hidden fields; range/from/until never leak in" do
    html = render_picker(extra_params: {scope_kind: "pod", scope_id: "web.aaaa", interval: "1m"})

    assert_includes html, 'type="hidden" name="scope_kind" value="pod"'
    assert_includes html, 'type="hidden" name="scope_id" value="web.aaaa"'
    assert_includes html, 'type="hidden" name="interval" value="1m"'
  end

  test "the custom popover carries From/Until inputs + UTC hidden companions" do
    html = render_picker(custom: true, from_iso: "2026-06-19T09:00:00Z", until_iso: "2026-06-19T10:00:00Z")

    assert_includes html, "time-range-filter-from-value=\"2026-06-19T09:00:00Z\""
    assert_includes html, "time-range-filter-until-value=\"2026-06-19T10:00:00Z\""
    assert_includes html, 'data-time-range-filter-target="fromInput"'
    assert_includes html, 'data-time-range-filter-target="untilHidden"'
    assert_includes html, "time-range-filter#applyCustom"
  end
end
