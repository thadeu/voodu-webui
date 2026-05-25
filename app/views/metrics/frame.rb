# frozen_string_literal: true

# Views::Metrics::Frame — the turbo-frame body that
# `polling_controller.js` reloads every 30s on the /metrics page.
#
# Renders ONLY the chart_grid (wrapped in a turbo_frame_tag with the
# same id the Index page uses). The surrounding chrome — sidebar,
# topbar, page header, scope/range pickers, replica chips — does NOT
# re-render on each tick; only the SVG paths + headline numbers swap.
#
# Mirror of Views::Logs::Frame (which does the same dance for the
# logs poller). Pattern: full-page Index hosts the frame element +
# polling controller; this Frame is what comes back over the wire on
# every reload tick. Turbo extracts the matching `<turbo-frame
# id="metrics-charts">` from the response and replaces its contents
# atomically — no scroll jump, no flash.
class Views::Metrics::Frame < Views::Base
  def initialize(data: nil)
    @data = data
  end

  def view_template
    turbo_frame_tag("metrics-charts") do
      # Defensive: a frame request without data is an edge case
      # (operator deleted the island between page open + tick).
      # Render an empty grid so Turbo still has a valid frame to
      # swap; the next full pageload will surface the real state.
      next if @data.nil?

      div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-3") do
        @data.charts.each do |c|
          render Components::Metrics::ChartCard.new(
            label:    c[:label],
            color:    c[:color],
            unit:     c[:unit],
            points:   c[:points],
            range_ms: @data.range_ms,
            current:  c[:current]
          )
        end
      end
    end
  end
end
