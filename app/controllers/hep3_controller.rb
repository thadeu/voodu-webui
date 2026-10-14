# frozen_string_literal: true

# Hep3Controller — HEP3 SIP-capture drill-downs. #call returns the call-flow
# ladder overlay for one correlated call (corr_id folds x_cid → call_id), an
# injected fragment like LogsAnalyticsController#surrounding: a call-flow icon
# fetches this, the host drops the HTML in, modal_controller takes over.
#
# #index is the /hep3 page: pick one reader, see its calls (Hep3PageData).
#
# Two entry points for #call:
#   • DataTable drill-down — explicit scope/name/corr_id (+ optional focus).
#     Params ride the query string (a SIP Call-ID carries `@`/`.`; path-
#     encoding is a footgun).
#   • Logs bridge — just a SIP `call_id` (from a FreeSWITCH log line). We
#     resolve the reader instance + corr_id from the read model, so the Logs
#     side needs nothing but the id.
class Hep3Controller < ApplicationController
  # The page exists only where the plugin does. The sidebar hides the item; this
  # closes the door for a typed or bookmarked URL too, after an uninstall.
  before_action :require_hep3_plugin!, only: [:index, :count, :display_settings]

  def index
    return redirect_to_reader if params[:reader].present?

    render Views::Hep3::Index.new(**dashboard_context.merge(data: page_data))
  end

  # count — the count card's polled frame body (Components::Hep3::CountFrame).
  # Same params as the page, so a poll always counts the window + filter the
  # operator sees.
  def count
    render Components::Hep3::CountFrame.new(data: page_data), layout: false
  end

  # display_settings — the Settings drawer: the same tiles UI as /metrics, over
  # the page's two panels. Kind "hep3" namespaces the stored layout.
  def display_settings
    render Views::Metrics::DisplaySettings.new(kind: "hep3", items: Hep3PageData::DISPLAY_ITEMS), layout: false
  end

  def call
    return head(:not_found) if reader_server.nil?

    data = call_flow_data

    return head(:not_found) if data.nil?

    # Render the modal even when the call has no messages — the operator gets
    # an in-overlay "Call not found" instead of a dead click.
    render Components::Hep3::CallFlowModal.new(data: data), layout: false
  end

  private

  # redirect_to_reader — the picker posts one radio, `reader=scope:name`; the
  # page itself speaks scope + name, so turn the pick into that URL (and drop
  # an empty filter) instead of teaching every link a second shape.
  def redirect_to_reader
    scope, name = params[:reader].to_s.split(":", 2)
    kept = request.query_parameters.slice(:range, :from, :until, :ws, :q).compact_blank

    redirect_to hep3_path(**kept.symbolize_keys, scope: scope, name: name)
  end

  def page_data
    Hep3PageData.new(
      server: current_server, scope: params[:scope], name: params[:name],
      range: params[:range], tab: params[:ws], q: params[:q], **custom_window
    )
  end

  def require_hep3_plugin!
    return if current_server&.plugin_installed?("hep3")

    redirect_to server_root_path, alert: "HEP3 is not installed on this server. Install the hep3 plugin to see its calls."
  end

  # custom_window — {from:, until_:} for `range=custom`, only when both bounds
  # parse and until_ > from; anything else collapses to the preset. Same rule
  # as MetricsController#custom_window, so one bookmark means the same window
  # on both pages.
  def custom_window
    return {from: nil, until_: nil} unless params[:range].to_s == "custom"

    from = parse_window_param(params[:from])
    until_ = parse_window_param(params[:until])

    (from && until_ && until_ > from) ? {from: from, until_: until_} : {from: nil, until_: nil}
  end

  def parse_window_param(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # reader_server — the server whose warehouse holds this call (M2). A
  # cross-server dashboard's hep3 table passes ?server_id=…; resolve it WITHIN
  # current_org (the isolation guard) so a forged / cross-org id never reads
  # another org's SIP capture. nil when the id names nothing in this org —
  # call_flow_data answers empty rather than quietly reading the URL's server.
  def reader_server
    return @reader_server if defined?(@reader_server)

    @reader_server = lookup_server
  end

  def call_flow_data
    server = reader_server
    return if server.nil?

    if params[:call_id].present?
      # Logs bridge: find any captured message with this SIP Call-ID → its
      # reader instance + corr_id (which folds x_cid). Not captured → an
      # empty-state modal carrying the id (a dead click still explains itself).
      message = HepMessage.locate_by_call_id(server, params[:call_id])

      return Hep3::CallFlowData.new(
        server: server,
        scope: message&.scope.to_s, name: message&.name.to_s,
        corr_id: message&.corr_id.presence || params[:call_id].to_s
      )
    end

    scope = params[:scope].to_s
    name = params[:name].to_s
    corr_id = params[:corr_id].to_s
    return nil if scope.empty? || name.empty? || corr_id.empty?

    Hep3::CallFlowData.new(
      server: server, scope: scope, name: name, corr_id: corr_id,
      focus_id: params[:focus]
    )
  end
end
