# frozen_string_literal: true

# Views::Metrics::Frame — the turbo-frame body returned when Turbo
# refetches the `metrics-charts` frame (broadcast tick over
# ActionCable, or manual frame.reload()).
#
# Renders ChartCards with data fetched server-side. Server-side
# fetch + Rails.cache (60s TTL) keeps the cold cost bounded; the
# warm path (1s after a tick) is sub-100ms.
#
# `Views::Metrics::Index#chart_grid` renders the SAME structure on
# initial pageload — keeping them lockstep means the broadcast
# swap doesn't visually flicker (same DOM in, same DOM out).
class Views::Metrics::Frame < Views::Base
  def initialize(data: nil)
    @data = data
  end

  def view_template
    turbo_frame_tag("metrics-charts") do
      next if @data.nil?

      div(class: "flex flex-col gap-4 vmd:gap-5") do
        render_grid(@data.charts)

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
          expand_url: expand_url_for(c)
        )
      end
    end
  end

  # expand_url_for — mirrors Views::Metrics::Index#expand_url_for.
  # Drift between the two = the maximize button breaks after the
  # first broadcast tick swap.
  def expand_url_for(chart)
    qp = {
      scope_kind: @data.scope_kind || "host",
      scope_id:   @data.scope_id,
      range:      @data.range || "1h",
      metric:     chart[:metric],
      scale:      chart[:scale],
      label:      chart[:label],
      color:      chart[:color],
      unit:       chart[:unit]
    }.compact

    "#{metrics_chart_path}?#{qp.to_query}"
  end
end
