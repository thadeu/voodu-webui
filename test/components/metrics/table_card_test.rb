# frozen_string_literal: true

require "test_helper"

# Components::Metrics::TableCard renders the Table panel: the data_table
# Stimulus mount (rows URL + source params), the column picker (every field,
# defaults pre-checked), the field filter, the pause control, and the
# grid/reload wiring (data-metric-key + turbo-permanent).
class Components::Metrics::TableCardTest < ActiveSupport::TestCase
  setup do
    controller = ApplicationController.new
    req = ActionDispatch::TestRequest.create
    req.path_parameters = {tenant_key: "ABC123", controller: "metrics", action: "index"}
    controller.request = req
    controller.response = ActionDispatch::TestResponse.new
    @view = controller.view_context
  end

  def render_card(**opts)
    base = {
      label: "SIP messages", color: "var(--voodu-teal)",
      source: "hep3", scope: "fsw", name: "hep3-api", view: "messages",
      rows_url: "/ABC123/metrics/datatable/hep3/rows",
      fields: %w[ts method from_user], default_fields: %w[ts method], metric: "k0"
    }

    Components::Metrics::TableCard.new(**base.merge(opts)).render_in(@view)
  end

  test "mounts the data_table controller with the rows URL + source params" do
    html = render_card

    assert_includes html, 'data-controller="data-table"'
    assert_includes html, 'data-data-table-url-value="/ABC123/metrics/datatable/hep3/rows"'
    assert_includes html, 'data-data-table-scope-value="fsw"'
    assert_includes html, 'data-data-table-name-value="hep3-api"'
    assert_includes html, 'data-data-table-view-value="messages"'
  end

  test "the column picker lists every field, defaults pre-checked" do
    html = render_card

    %w[ts method from_user].each { |f| assert_includes html, "value=\"#{f}\"" }
    assert_includes html, "Select all / clear"
    # default_fields (ts, method) render checked; from_user does not.
    assert_equal 2, html.scan(/type="checkbox"[^>]*checked/).size
  end

  test "seeds the toolbar query from the panel's config filter" do
    html = render_card(filter_query: "@to_user like /5511/")

    assert_includes html, "data-data-table-target=\"query\""
    assert_includes html, 'value="@to_user like /5511/"'
  end

  test "the toolbar has the query filter + refresh and live controls" do
    html = render_card

    assert_includes html, "data-data-table-target=\"query\""
    assert_includes html, "data-table#refresh"
    assert_includes html, "data-data-table-target=\"live\""
  end

  ROW_ACTION = {key: "corr_id", event: "callflow", title: "Open call-flow", icon: "ArrowsRightLeftOutline"}.freeze

  test "a row_action wires the drill-down values + ships the icon in a template" do
    html = render_card(row_action: ROW_ACTION)

    assert_includes html, 'data-data-table-row-action-key-value="corr_id"'
    assert_includes html, 'data-data-table-row-action-event-value="callflow"'
    assert_includes html, 'data-data-table-row-action-title-value="Open call-flow"'
    assert_includes html, 'data-data-table-target="rowActionIcon"'
    assert_includes html, "<template", "the icon rides in a <template> the controller clones per row"
    assert_includes html, "<svg", "the Heroicon is rendered into the template"
  end

  test "no row_action (e.g. logs source) renders no action wiring" do
    html = render_card(row_action: nil)

    assert_not_includes html, "row-action-key-value"
    assert_not_includes html, 'data-data-table-target="rowActionIcon"'
  end

  test "carries the grid wiring + a stable id, and is NOT turbo-permanent" do
    html = render_card

    assert_includes html, 'data-metric-key="k0"'
    assert_includes html, 'id="dt-k0"'
    # turbo-permanent fights the metrics-display reorder — the table must
    # re-render normally so applyOrder keeps it where the operator put it.
    assert_not_includes html, "turbo-permanent"
  end
end
