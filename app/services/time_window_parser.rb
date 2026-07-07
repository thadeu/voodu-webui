# frozen_string_literal: true

# TimeWindowParser — turns `range` / `from` / `until` params into a
# [from, until] Time window. Shared by the log-search + alert-history filters:
# same "presets or explicit custom" logic, only the config differs.
#
# Semantics (identical to both callers before extraction):
#   - `range` is a known preset key, or "custom", or the default. A bare
#     from/until with no range reads as custom, and once custom it STAYS custom
#     even with a missing bound — falling back to a preset would silently
#     discard the operator's choice.
#   - a custom window uses the parsed inputs (a blank `from` defaults to
#     `custom_blank_from` before `until`, never nil); presets are relative to now.
#   - `retention` (optional) hard-floors `from` so we never scan reaped data.
class TimeWindowParser
  def initialize(params = {}, ranges:, default_range:, custom_blank_from: 1.hour, retention: nil)
    @params = (params || {}).to_h.symbolize_keys
    @ranges = ranges
    @default_range = default_range
    @custom_blank_from = custom_blank_from
    @retention = retention
  end

  def range
    @range ||= begin
      r = @params[:range].to_s

      if r == "custom" || (r.blank? && parsed_from)
        "custom"
      else
        @ranges.key?(r) ? r : @default_range
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

  # window — [from, until] Time objects. Custom uses the parsed inputs (blank
  # from defaults to one `custom_blank_from` before until rather than nil);
  # presets are relative to now. `from` is clamped to the retention floor when
  # one is set, so we never walk reaped territory.
  def window
    @window ||= begin
      now = Time.current

      if custom?
        u = parsed_until || now
        f = parsed_from || (u - @custom_blank_from)
      else
        f = @ranges.fetch(range).ago
        u = now
      end

      f = [f, @retention.ago].max if @retention

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
