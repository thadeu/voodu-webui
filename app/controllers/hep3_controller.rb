# frozen_string_literal: true

# Hep3Controller — HEP3 SIP-capture drill-downs off the Metrics DataTable.
#
# #call returns the call-flow ladder overlay for one correlated call
# (corr_id folds x_cid → call_id). It's an injected fragment, exactly like
# LogsAnalyticsController#surrounding: the DataTable row's call-flow icon
# fetches this, the host drops the HTML in and modal_controller takes over.
#
# corr_id / scope / name ride as query params (a SIP Call-ID carries `@`
# and `.` — path-encoding is a footgun; query is safe). scope/name pick
# the reader instance the row came from.
class Hep3Controller < ApplicationController
  def call
    return head(:not_found) if current_island.nil?

    scope = params[:scope].to_s
    name = params[:name].to_s
    corr_id = params[:corr_id].to_s

    return head(:not_found) if scope.empty? || name.empty? || corr_id.empty?

    data = Hep3::CallFlowData.new(
      island: current_island, scope: scope, name: name, corr_id: corr_id,
      focus_id: params[:focus]
    )

    # Render the modal even when the call has no messages — the operator
    # gets an in-overlay "Call not found" instead of a dead click.
    render Components::Hep3::CallFlowModal.new(data: data), layout: false
  end
end
