# frozen_string_literal: true

require "test_helper"

# The chart-expand modal is url-state-first: a refresh with mx_* params in the
# URL re-fetches the chart to re-open the modal. For that the scaffold must
# carry the /metrics/chart endpoint so the controller can rebuild the fetch URL.
class Components::Metrics::ChartModalTest < ActiveSupport::TestCase
  setup do
    controller = ApplicationController.new
    req = ActionDispatch::TestRequest.create
    req.path_parameters = {org_id: "abcd1234", server_key: "ABC123", controller: "metrics", action: "index"}
    controller.request = req
    controller.response = ActionDispatch::TestResponse.new
    @view = controller.view_context
  end

  test "renders the /metrics/chart endpoint as a stimulus value for hydration" do
    html = Components::Metrics::ChartModal.new.render_in(@view)

    assert_includes html, 'id="chart-modal"'
    assert_includes html, "data-chart-modal-chart-path-value"
    assert_includes html, "/metrics/chart"
  end
end
