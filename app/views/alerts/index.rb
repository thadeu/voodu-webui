# frozen_string_literal: true

# Views::Alerts::Index — the /alerts page. Firing episodes up top
# (red cards), then the rules table, then resolved history.
#
# Liveness: the page subscribes to `alerts-#{island.id}`; every
# fire/resolve transition broadcasts an `alerts_tick` action (see
# turbo_actions/alerts.js) that reloads the `alerts-live` frame —
# the same body Views::Alerts::Frame returns, so the swap is
# DOM-stable.
class Views::Alerts::Index < Views::Base
  def initialize(current_path:, islands: [], current_island: nil, data: nil)
    @current_path   = current_path
    @islands        = islands
    @current_island = current_island
    @data           = data
  end

  def view_template
    render Components::Layouts::Dashboard.new(
      current_path: @current_path, islands: @islands, current_island: @current_island
    ) do
      if @current_island.nil?
        render Components::UI::NoIslandState.new
      else
        body
      end
    end
  end

  private

  def body
    div(class: "px-3.5 vmd:px-6 py-4 vmd:py-5 flex flex-col gap-4 vmd:gap-5") do
      turbo_stream_from "alerts-#{@current_island.id}"

      page_head

      # `src` is what makes the live update work: the alerts_tick
      # broadcast calls frame.reload(), and reload() refetches `src`.
      # Without it reload() is a silent no-op (same wiring the
      # metrics-charts frame uses). The inline body renders
      # immediately; Turbo then eager-loads the identical Frame view
      # (AlertsController detects the Turbo-Frame header), so the
      # first paint isn't blocked on the refetch.
      #
      # target: "_top" so links/forms INSIDE the frame (Edit, the
      # empty-state buttons) navigate the whole page instead of being
      # frame-scoped — a frame-scoped Edit fetches the modal page,
      # finds no matching <turbo-frame id="alerts-live"> in it, and
      # Turbo renders "Content missing". Programmatic frame.reload()
      # still reloads just this frame regardless of target.
      turbo_frame_tag("alerts-live", src: current_request_url, target: "_top") do
        div(class: "flex flex-col gap-4 vmd:gap-5") do
          render Components::Alerts::LiveBody.new(data: @data)
        end
      end
    end
  end

  # Request path + query string for the frame `src` — refetches the
  # exact page the operator is on. Re-serialised via to_query rather
  # than request.original_url so a non-default dev port doesn't turn
  # the reload into a cross-origin fetch (same rationale as the
  # metrics page).
  def current_request_url
    qs = request.query_parameters.to_query
    qs.present? ? "#{request.path}?#{qs}" : request.path
  end

  def page_head
    render(
      Components::UI::PageHeader.new(title: "Alerts")
        .with_subtitle { page_sub }
        .with_actions { head_actions }
    )
  end

  # Static copy on purpose — the firing count lives INSIDE the live
  # frame (section heads), so the subtitle can't go stale between
  # broadcast ticks.
  def page_sub
    span do
      plain "Threshold rules over the metrics warehouse · evaluated every 30s"
    end
  end

  def head_actions
    render Components::UI::Button.new(
      variant: :primary, size: :md, tag: :a, href: new_alert_rule_path
    ) do
      render Icon::PlusOutline.new(class: "w-3.5 h-3.5")
      span(class: "hidden vmd:inline") { "New rule" }
    end
  end
end
