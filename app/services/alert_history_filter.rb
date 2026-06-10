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
  RANGES = {
    "24h" => 24.hours,
    "7d"  => 7.days,
    "30d" => 30.days
  }.freeze

  DEFAULT_RANGE = "7d"

  def initialize(params = {})
    @params = (params || {}).to_h.symbolize_keys
  end

  def range
    @range ||= begin
      r = @params[:range].to_s
      if r == "custom" || (r.blank? && parsed_from)
        "custom"
      else
        RANGES.key?(r) ? r : DEFAULT_RANGE
      end
    end
  end

  def custom?
    range == "custom"
  end

  def from
    window.first
  end

  def until_
    window.last
  end

  # window — [from, until] Time objects. Custom uses the parsed inputs
  # (blank from defaults to one window before until rather than nil);
  # presets are relative to now.
  def window
    @window ||= begin
      now = Time.current

      if custom?
        u = parsed_until || now
        f = parsed_from  || (u - 1.day)
      else
        f = RANGES.fetch(range).ago
        u = now
      end

      [f, u]
    end
  end

  def from_iso
    from.utc.iso8601(3)
  end

  def until_iso
    until_.utc.iso8601(3)
  end

  private

  def parsed_from
    return @parsed_from if defined?(@parsed_from)

    @parsed_from = parse_time(@params[:from])
  end

  def parsed_until
    return @parsed_until if defined?(@parsed_until)

    @parsed_until = parse_time(@params[:until])
  end

  def parse_time(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
