# frozen_string_literal: true

# AlertHistoryFilter — parses the History tab's time-range params into
# a [from, until] window, mirroring LogSearchData's logic. Ranges are
# alert-appropriate (incidents span days, not the minutes logs do):
# 24h / 7d / 30d, plus an explicit custom window.
#
# Once the operator picks Custom it STAYS custom even with a missing
# from/until — falling back to a preset there would silently discard
# their choice. A bare from/until with no range also reads as custom.
class AlertHistoryFilter
  extend Forwardable

  RANGES = {
    "24h" => 24.hours,
    "7d" => 7.days,
    "30d" => 30.days
  }.freeze

  DEFAULT_RANGE = "7d"

  # No retention floor (alert events are kept indefinitely); a custom blank
  # `from` falls back a day before `until` (incidents span days, not minutes).
  def initialize(params = {})
    @window = TimeWindowParser.new(
      params,
      ranges: RANGES,
      default_range: DEFAULT_RANGE,
      custom_blank_from: 1.day
    )
  end

  def_delegators :@window, :range, :custom?, :window, :from, :until_, :from_iso, :until_iso
end
