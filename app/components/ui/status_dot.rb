# frozen_string_literal: true

# Components::UI::StatusDot — 7px dot used in dense lists (pod table,
# island sidebar) to convey running/restarting/offline without taking
# a full pill's width.
#
# Ported from the inspiration HTML's <StatusDot> (parts.jsx). The
# glow ring (box-shadow at 18% alpha) is the trick that makes it
# read at small sizes — without it the dot looks like a colored
# pixel rather than a deliberate indicator.
#
# `pulse: true` adds a 2.4s ease pulse — apply to live "running" /
# "online" states. Static states (stopped, error) skip it on purpose
# so the eye is not constantly drawn.
class Components::UI::StatusDot < Components::Base
  COLOR = {
    online: "var(--voodu-green)",
    running: "var(--voodu-green)",
    restarting: "var(--voodu-amber)",
    offline: "var(--voodu-red)",
    error: "var(--voodu-red)",
    stopped: "var(--voodu-muted)",
    pending: "var(--voodu-muted)",
    # unknown reads as an alert (red), same as offline — a missing health
    # status is a problem, not a neutral state.
    unknown: "var(--voodu-red)"
  }.freeze

  def initialize(status:, size: 7, pulse: nil)
    @status = status.to_sym
    @size = size
    # Pulse defaults to true for live states, false for terminal ones.
    @pulse = pulse.nil? ? @status.in?(%i[online running restarting]) : pulse
  end

  def view_template
    color = COLOR.fetch(@status, COLOR[:stopped])

    span(
      class: tokens("inline-block shrink-0 rounded-full", ("animate-voodu-pulse" if @pulse)),
      style: "width: #{@size}px; height: #{@size}px; background: #{color}; " \
             "box-shadow: 0 0 0 3px color-mix(in srgb, #{color} 18%, transparent);",
      aria: {label: @status.to_s, role: "status"}
    )
  end
end
