# frozen_string_literal: true

# Components::Metrics::GaugeLinear — horizontal capacity bar for a
# capacity / percent metric: a big % up top, a filled track, and the
# used / total figures underneath. The fill tints AMBER past 70% and
# RED past 90% (same thresholds as GaugeRadial / the pod CPU bar).
#
# Rendered by Components::Metrics::ChartCard when chart_type is
# "gauge_linear". ChartCard does the formatting; this only draws.
class Components::Metrics::GaugeLinear < Components::Base
  def initialize(pct:, color:, value_label: nil, capacity_label: nil)
    @pct = clamp(pct.to_f)
    @color = color
    @value_label = value_label
    @capacity_label = capacity_label
  end

  def view_template
    div(class: "flex flex-col justify-center gap-3 py-4 min-h-[120px]") do
      span(class: "font-voodu-mono text-[26px] font-semibold text-voodu-text leading-none") { pct_label }

      div(
        class: "h-3.5 w-full bg-voodu-surface-3 overflow-hidden rounded-voodu-sm"
      ) do
        div(style: "width: #{@pct.round(1)}%; height: 100%; background: #{fill_color};")
      end

      if @value_label.present? || @capacity_label.present?
        div(class: "flex items-center justify-between font-voodu-mono text-[11px] text-voodu-muted") do
          span { @value_label.to_s.presence || "—" }
          span { @capacity_label.to_s.presence || "" }
        end
      end
    end
  end

  private

  def fill_color
    return "var(--voodu-red)" if @pct >= 90
    return "var(--voodu-amber)" if @pct >= 70

    @color
  end

  def pct_label
    # String#% — `format`/`sprintf` resolve to a shadowed 0-arg helper
    # in the Phlex component context (same reason PodCard uses "%.1f" % v).
    (@pct < 10) ? "#{"%.1f" % @pct}%" : "#{@pct.round}%"
  end

  def clamp(v)
    return 0.0 if v.negative?
    return 100.0 if v > 100

    v
  end
end
