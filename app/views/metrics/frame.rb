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
#
# Resource + HTTP cards share ONE grid (no divider). Each HTTP card
# carries an inline [http] badge inside its header so the visual
# cue remains without breaking the grid.
class Views::Metrics::Frame < Views::Base
  def initialize(data: nil)
    @data = data
  end

  def view_template
    turbo_frame_tag("metrics-charts") do
      next if @data.nil?

      # metrics-display controller: mirrors the wrapper in
      # Views::Metrics::Index#chart_grid. Must carry the same
      # controller + kindValue so the hide-filter + custom ordering
      # re-apply correctly after each broadcast-tick swap.
      div(
        class: "flex flex-col gap-4 vmd:gap-5",
        data: {
          controller:                 "metrics-display",
          metrics_display_kind_value: @data.display_kind
        }
      ) do
        all_charts = @data.charts + (@data.ingress_eligible? ? @data.http_charts : [])
        render_grid(all_charts)
      end
    end
  end

  private

  def render_grid(charts)
    div(
      class: "grid grid-cols-1 vmd:grid-cols-2 gap-3",
      data:  { metrics_display_target: "grid" }
    ) do
      charts.each do |c|
        render Components::Metrics::ChartCard.new(
          label:           c[:label],
          color:           c[:color],
          unit:            c[:unit],
          points:          c[:points],
          range_ms:        @data.range_ms,
          current:         c[:current],
          expand_url:      expand_url_for(c),
          metric:          c[:metric],
          section:         c[:section],
          default_visible: c.fetch(:default_visible, true)
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
      # Match Views::Metrics::Index#expand_url_for — omit `interval`
      # when `auto` so URLs stay clean on the default path.
      interval:   (@data.interval && @data.interval != "auto") ? @data.interval : nil,
      metric:     chart[:metric],
      scale:      chart[:scale],
      label:      chart[:label],
      color:      chart[:color],
      unit:       chart[:unit]
    }.compact

    "#{metrics_chart_path}?#{qp.to_query}"
  end
end
