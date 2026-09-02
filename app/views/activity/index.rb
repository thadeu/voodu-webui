# frozen_string_literal: true

# Views::Activity::Index — the /activity page: what was DONE to this server.
#
# Liveness: the page subscribes to `activity-#{server.id}`; every digest the
# poller lands broadcasts an `activity_tick` (see turbo_actions/activity.js)
# that reloads the `activity-table` frame. That is what makes a running action
# close itself on screen — the one state on this page that moves.
class Views::Activity::Index < Views::Base
  def initialize(current_path:, servers: [], current_server: nil, data: nil)
    @current_path = current_path
    @servers = servers
    @current_server = current_server
    @data = data
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, servers: @servers, current_server: @current_server,
      breadcrumb: overview_crumbs({label: "Activity"})
    ) do
      if @current_server.nil?
        render Components::UI::NoServerState.new
      else
        body
      end
    end
  end

  private

  def body
    div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
      # `class: "hidden"` keeps this invisible source out of the flex flow —
      # as the leading child it would otherwise eat one gap and push the title
      # down. connectedCallback still fires for display:none nodes, so the
      # subscription is unaffected. Same trick the alerts page uses.
      turbo_stream_from "activity-#{@current_server.id}", class: "hidden"

      page_head

      # `src` is what makes the live reload work: activity_tick calls
      # frame.reload(), and reload() refetches src. Without it the call is a
      # silent no-op. The inline body renders immediately so the first paint
      # is not blocked on the refetch.
      #
      # target: "_top" so a filter chip inside the frame that the operator
      # cmd-clicks, or any future link out of a row, navigates the page
      # instead of looking for this frame in the destination.
      turbo_frame_tag(ActivityController::FRAME, src: current_request_url, target: "_top") do
        render Components::Activity::Body.new(data: @data)
      end
    end
  end

  # Re-serialised from query_parameters rather than request.original_url so a
  # non-default dev port does not turn the reload into a cross-origin fetch.
  def current_request_url
    qs = request.query_parameters.to_query
    qs.present? ? "#{request.path}?#{qs}" : request.path
  end

  def page_head
    render(
      Components::UI::PageHeader.new(title: "Activity")
        .with_subtitle { page_sub }
    )
  end

  # Names what the page is NOT, because that is the question it invites: this
  # is the operator's own actions, not the platform's reconciles.
  #
  # The server is a chip rather than the words "this server". A trail is the
  # screen people reach for while switching between boxes to work out where
  # something happened, and "this" is exactly the word that stops answering
  # once you have three tabs open.
  def page_sub
    span(class: "inline-flex flex-wrap items-center gap-1.5") do
      plain "Applies, restarts, deletes, rollbacks and config changes on"

      render Components::UI::Chip.new(tone: :accent, mono: true) { @current_server.name }

      plain "· kept 30 days"
    end
  end
end
