# frozen_string_literal: true

# MetricFormat — magnitude-adaptive decimal formatting for the
# metrics surfaces (ChartCard headline + min/avg/max chips, Chart's
# Y-axis labels, tooltip via MetricsData#formatter_for).
#
# Why this exists: a flat `"%.1f"` (or `"%.1f%%"` for cpu_percent)
# floors any sub-0.1 value to `"0.0"` — which made an idle pod
# read as 0% across the entire chart even though the sparkline
# clearly showed real activity (peaks at 0.05–0.1%). The vertical
# position of each point uses the raw value, so the SHAPE was
# right but every NUMBER lied.
#
# Tiers (mirror operator intuition: "show enough precision for
# the magnitude I'm looking at"):
#
#   ≥ 100   → 0 decimals       ("142")
#   ≥ 10    → 1 decimal        ("42.5")
#   ≥ 1     → 1 decimal        ("4.2")
#   ≥ 0.01  → 2 decimals       ("0.05")
#   > 0     → "<0.01"          (don't pretend to render 0.0001)
#   = 0     → "0"              (clean exact zero)
#
# Two surfaces:
#
#   .number(v)         → just the bare number string
#   .percent(v)        → same tiers, appended with "%" + ensures
#                        the zero case is "0%" not "0.0%"
#
# Used by:
#   - MetricsData#formatter_for (per-metric tooltip strings)
#   - Components::Metrics::ChartCard#format_current / #format_value
#   - Components::Metrics::Chart#format_axis_number
module MetricFormat
  module_function

  def number(v)
    return "—" if v.nil?
    return "0" if v.zero?

    abs = v.abs
    return v.round.to_s if abs >= 100
    return v.round(1).to_s if abs >= 10
    return v.round(1).to_s if abs >= 1
    return v.round(2).to_s if abs >= 0.01

    "<0.01"
  end

  def percent(v)
    return "—" if v.nil?
    return "0%" if v.zero?

    abs = v.abs
    return "#{v.round}%" if abs >= 100
    return format("%.1f%%", v) if abs >= 1
    return format("%.2f%%", v) if abs >= 0.01

    "<0.01%"
  end
end
