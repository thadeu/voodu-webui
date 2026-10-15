# frozen_string_literal: true

# Views::Fswapi::Index — the FreeSWITCH page (voodu-fswapi plugin) for one
# server: status, the count cards with their 1h history, and the live lists.
#
# Only the chrome and the heading live here; everything that changes sits in
# a polled turbo-frame (Components::Fswapi::Body), refreshed every POLL_MS —
# the cadence the overview is sampled at, so each tick can show a new point.
class Views::Fswapi::Index < Views::Base
  POLL_MS = 15_000

  def initialize(current_path:, servers: [], current_server: nil, data: nil, **)
    @current_path = current_path
    @servers = servers
    @current_server = current_server
    @data = data
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers, current_server: @current_server,
      breadcrumb: overview_crumbs({label: "FreeSWITCH"})
    ) do
      if @current_server.nil? || @data.nil?
        render Components::UI::NoServerState.new
      else
        div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
          page_head
          live_frame
        end

        # Outside the polled frame, like on Metrics and HEP3: an open SIP
        # ladder must survive the 15s refresh.
        if @data.call_flow?
          render Components::Hep3::CallFlowHost.new(call_url: metrics_hep3_call_path(server_key: @current_server.key))
        end
      end
    end
  end

  private

  # page_head, not `header` — that is a Phlex HTML tag method.
  def page_head
    div(class: "flex flex-col gap-1") do
      h1(class: "text-[17px] font-semibold text-voodu-text") { "FreeSWITCH" }
      p(class: "text-[12.5px] text-voodu-muted") do
        plain "Live state of the PBX on this server, read through the voodu-fswapi plugin."
      end
    end
  end

  def live_frame
    div(data: {controller: "polling", polling_interval_value: POLL_MS}) do
      turbo_frame_tag(FswapiController::FRAME, src: fswapi_path(view: @data.view, q: @data.q.presence)) do
        render Components::Fswapi::Body.new(data: @data)
      end
    end
  end
end
