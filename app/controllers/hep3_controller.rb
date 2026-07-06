# frozen_string_literal: true

# Hep3Controller — HEP3 SIP-capture drill-downs. #call returns the call-flow
# ladder overlay for one correlated call (corr_id folds x_cid → call_id), an
# injected fragment like LogsAnalyticsController#surrounding: a call-flow icon
# fetches this, the host drops the HTML in, modal_controller takes over.
#
# Two entry points:
#   • DataTable drill-down — explicit scope/name/corr_id (+ optional focus).
#     Params ride the query string (a SIP Call-ID carries `@`/`.`; path-
#     encoding is a footgun).
#   • Logs bridge — just a SIP `call_id` (from a FreeSWITCH log line). We
#     resolve the reader instance + corr_id from the read model, so the Logs
#     side needs nothing but the id.
class Hep3Controller < ApplicationController
  def call
    return head(:not_found) if reader_island.nil?

    data = call_flow_data

    return head(:not_found) if data.nil?

    # Render the modal even when the call has no messages — the operator gets
    # an in-overlay "Call not found" instead of a dead click.
    render Components::Hep3::CallFlowModal.new(data: data), layout: false
  end

  private

  # reader_island — the server whose warehouse tenant holds this call (M2). A
  # cross-server dashboard's hep3 table passes ?island_id=…; resolve it WITHIN
  # current_org (the isolation guard) so a forged / cross-org id never reads
  # another org's SIP capture — it falls back to the URL's server.
  def reader_island
    return @reader_island if defined?(@reader_island)

    @reader_island =
      if params[:island_id].present? && current_org
        current_org.islands.find_by(id: params[:island_id]) || current_island
      else
        current_island
      end
  end

  def call_flow_data
    island = reader_island

    if params[:call_id].present?
      # Logs bridge: find any captured message with this SIP Call-ID → its
      # reader instance + corr_id (which folds x_cid). Not captured → an
      # empty-state modal carrying the id (a dead click still explains itself).
      message = HepMessage.locate_by_call_id(island.id, params[:call_id])

      return Hep3::CallFlowData.new(
        island: island,
        scope: message&.scope.to_s, name: message&.name.to_s,
        corr_id: message&.corr_id.presence || params[:call_id].to_s
      )
    end

    scope = params[:scope].to_s
    name = params[:name].to_s
    corr_id = params[:corr_id].to_s
    return nil if scope.empty? || name.empty? || corr_id.empty?

    Hep3::CallFlowData.new(
      island: island, scope: scope, name: name, corr_id: corr_id,
      focus_id: params[:focus]
    )
  end
end
