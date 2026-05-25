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

      div(class: "flex flex-col gap-4 vmd:gap-5") do
        # Resource charts — always present.
        render_grid(@data.charts)

        # HTTP charts — conditional. Same eligibility used by the
        # full Index view; both surfaces hide/show in lockstep so
        # the polling tick doesn't add or remove the section
        # spuriously between renders.
        if @data.ingress_eligible?
          div(class: "flex flex-col gap-2.5") do
            h2(
              class: "text-[10.5px] font-semibold uppercase tracking-[0.08em] font-voodu-mono text-voodu-muted flex items-center gap-2"
            ) do
              span { "HTTP" }
              span(class: "flex-1 h-px bg-voodu-border")
              span(class: "font-normal text-voodu-muted-2 normal-case tracking-normal") { "ingress · same range" }
            end

            render_grid(@data.http_charts)
          end
        end
      end
    end
  end

  private

  def render_grid(charts)
    div(class: "grid grid-cols-1 vmd:grid-cols-2 gap-3") do
      charts.each do |c|
        render Components::Metrics::ChartCard.new(
          label:      c[:label],
          color:      c[:color],
          unit:       c[:unit],
          points:     c[:points],
          range_ms:   @data.range_ms,
          current:    c[:current],
          expand_url: expand_url_for(c),
          metric:     c[:metric]
        )
      end
    end
  end

  # expand_url_for — mirrors Views::Metrics::Index#expand_url_for
  # exactly so the maximize button works on both initial pageload
  # (Index) AND post-poll-tick swaps (this Frame). Drift between
  # the two would mean the button disappears or 404s after the
  # first 30s tick — pin them together.
  def expand_url_for(chart)
    qp = request.query_parameters
    params = {
      scope_kind: qp[:scope_kind] || @data.scope_kind,
      scope_id:   qp[:scope_id]   || @data.scope_id,
      range:      qp[:range]      || @data.range || "1h",
      metric:     chart[:metric],
      scale:      chart[:scale],
      label:      chart[:label],
      color:      chart[:color],
      unit:       chart[:unit]
    }.compact

    "#{metrics_chart_path}?#{params.to_query}"
  end
end
