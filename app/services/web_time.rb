# frozen_string_literal: true

# WebTime — single conversion point for "render this UTC moment in
# the operator's preferred timezone."
#
# Why a wrapper instead of `Time.use_zone` / `Time.zone = ...`?
#
#   Rails' `Time.zone` is process-global per Rails thread, and we
#   render Phlex views from many call sites — chart axis ticks,
#   sidebar synced-at chips, About card boot time, etc. Threading
#   `Time.zone` through them via `use_zone` blocks would mean
#   wrapping each render entrypoint, which we'd inevitably miss.
#   This class is the explicit "convert + format" seam — callers
#   that go through it always get the configured TZ; callers that
#   don't get UTC by accident, which is the same as today.
#
# Usage:
#
#   WebTime.zone_name           # → "America/Sao_Paulo" (or "UTC")
#   WebTime.zone                # → ActiveSupport::TimeZone
#   WebTime.in_zone(some_time)  # → TimeWithZone in operator's TZ
#   WebTime.strftime(t, "%H:%M:%S")
#   WebTime.iso8601(t)
#   WebTime.valid_zone?("America/Sao_Paulo")  # → true/false
#
# Inputs accepted: Time, DateTime, ActiveSupport::TimeWithZone,
# Date (midnight UTC), Numeric (unix epoch seconds), or ISO8601
# strings. Anything else returns nil — no exceptions for malformed
# data so views can render `—` instead of 500-ing.
#
# Performance: zone lookup hits the Settings table once per request
# via the per-request cache in `current_zone`. The lookup is sub-
# millisecond on SQLite and the result fits in a request-scoped
# memo, so per-view-render cost is effectively zero.
class WebTime
  DEFAULT_ZONE_NAME = "UTC"

  # zone_name — the IANA name to render timestamps in. The current org's
  # timezone (a per-org display preference) when it's set to a zone
  # ActiveSupport recognises, else "UTC". Resolved once per request and
  # cached as a Ruby string for the rest of the render.
  #
  # Org-less pages (servers list, org manager, onboarding) and background
  # jobs have no org in scope, so they render in UTC — none of them show
  # metric charts, so there's no timezone to get wrong there.
  def self.zone_name
    cache = request_cache
    return cache[:zone_name] if cache.key?(:zone_name)

    raw = org_zone_name
    name = (raw && valid_zone?(raw)) ? raw : DEFAULT_ZONE_NAME
    cache[:zone_name] = name
  rescue ActiveRecord::StatementInvalid
    # Migration hasn't run yet (boot before migrate, test setup,
    # rake db:reset between calls). Falling back keeps the app
    # bootable; once the migration lands the lookup succeeds.
    DEFAULT_ZONE_NAME
  end

  # org_zone_name — the current request's org timezone, or nil when there's
  # no org in scope (org-less pages, jobs) or it isn't set. Guarded so a
  # non-request context (Current unset) never raises.
  def self.org_zone_name
    Current.org&.timezone.to_s.strip.presence
  rescue
    nil
  end

  # zone — ActiveSupport::TimeZone instance for the configured
  # name. Already validated by `zone_name` so this never returns
  # nil (it falls back to UTC's TimeZone).
  def self.zone
    ActiveSupport::TimeZone[zone_name] || ActiveSupport::TimeZone[DEFAULT_ZONE_NAME]
  end

  # valid_zone? — true when ActiveSupport recognises the name.
  # Used by the Settings form to validate operator input before
  # persisting; also used internally by `zone_name` so bad data
  # in the DB silently degrades to UTC instead of crashing renders.
  def self.valid_zone?(name)
    return false if name.blank?

    !!ActiveSupport::TimeZone[name.to_s]
  end

  # in_zone — coerce anything time-shaped into a TimeWithZone in
  # the operator's configured TZ. Returns nil for nil/blank inputs
  # so callers can chain `&.strftime(...)` without explicit guards.
  def self.in_zone(input)
    t = coerce(input)
    return nil if t.nil?

    t.in_time_zone(zone)
  end

  # strftime — convenience wrapper. `WebTime.strftime(t, "%H:%M")`
  # is the canonical replacement for `t.utc.strftime("%H:%M")` at
  # render sites that want operator-local times.
  def self.strftime(input, pattern)
    z = in_zone(input)
    return nil if z.nil?

    z.strftime(pattern)
  end

  # iso8601 — same as strftime but emitting the ISO8601 form.
  # Useful when client-side JS needs to consume the timestamp.
  def self.iso8601(input)
    in_zone(input)&.iso8601
  end

  # clear_request_cache — reset the per-request zone memo. Called at the
  # START of every request (ApplicationController before_action) so a thread
  # recycled across requests doesn't carry a stale zone from a previous org.
  def self.clear_request_cache
    Thread.current[:web_time_cache] = nil
  end

  # ── private helpers ──────────────────────────────────────────

  # request_cache — thread-local hash, reset on each Rails request
  # via a before_action in ApplicationController. Stores `:zone_name`
  # so we don't re-resolve the org's zone for each view that asks
  # for a TZ conversion.
  def self.request_cache
    Thread.current[:web_time_cache] ||= {}
  end
  private_class_method :request_cache

  # coerce — best-effort normalisation. Returns a Time / DateTime /
  # TimeWithZone (any of which respond to `in_time_zone`), or nil
  # if the input shape isn't recognised. Bad strings (typoed ISO,
  # empty string) → nil; views render "—" instead of 500-ing.
  def self.coerce(input)
    return nil if input.nil?

    case input
    when ActiveSupport::TimeWithZone, Time, DateTime
      input
    when Date
      input.to_time
    when Numeric
      # Seconds since epoch. Matches the controller's `time` field
      # which we serialise as unix seconds in /metrics responses.
      Time.at(input)
    when String
      parse_string(input)
    end
  end
  private_class_method :coerce

  # parse_string — try ISO8601 first (the wire format we ship
  # from the controller) then fall back to Time.parse. Both raise
  # ArgumentError on garbage; we rescue and return nil so the
  # render path stays clean.
  def self.parse_string(str)
    s = str.strip
    return nil if s.empty?

    Time.iso8601(s)
  rescue ArgumentError
    begin
      Time.parse(s)
    rescue ArgumentError
      nil
    end
  end
  private_class_method :parse_string
end
