# frozen_string_literal: true

# Components::Hep3::CallFlowHost — the page-level mount point for the SIP
# call-flow overlay. Rendered ONCE on the Metrics page, OUTSIDE the polling
# turbo-frame (same placement as Components::Metrics::ChartModal) so an open
# ladder survives a broadcast-tick frame reload.
#
# hep3_call_flow_controller.js listens for a DataTable row's
# `datatable:rowaction` (event = "callflow"), fetches the ladder fragment
# for that corr_id from `call_url`, and injects it into the host — the same
# fetch→inject the Logs "surrounding" modal uses.
class Components::Hep3::CallFlowHost < Components::Base
  def initialize(call_url:)
    @call_url = call_url
  end

  def view_template
    div(data: {controller: "hep3-call-flow", hep3_call_flow_url_value: @call_url}) do
      div(data: {hep3_call_flow_target: "host"})
    end
  end
end
