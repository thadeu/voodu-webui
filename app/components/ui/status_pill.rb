# frozen_string_literal: true

# Components::UI::StatusPill — labeled status indicator. Used in
# detail headers (e.g. "Running" next to a pod title), in the pods
# table's status column, and in the topbar (island health).
#
# Ports the <StatusPill> from parts.jsx. Each status maps to a
# (label, color, bg) triple from the voodu palette. The dot inside
# is shared with StatusDot (same glow ring trick).
#
# `restarting` swaps the dot for a Spinner so transient states feel
# alive rather than just colored.
class Components::UI::StatusPill < Components::Base
  STATES = {
    running: {label: "Running", color: "var(--voodu-green)", bg: "var(--voodu-green-dim)"},
    online: {label: "Online", color: "var(--voodu-green)", bg: "var(--voodu-green-dim)"},
    restarting: {label: "Restarting", color: "var(--voodu-amber)", bg: "var(--voodu-amber-dim)"},
    offline: {label: "Offline", color: "var(--voodu-red)", bg: "var(--voodu-red-dim)"},
    error: {label: "Error", color: "var(--voodu-red)", bg: "var(--voodu-red-dim)"},
    stopped: {label: "Stopped", color: "var(--voodu-muted)", bg: "#7a7a8818"},
    pending: {label: "Pending", color: "var(--voodu-muted)", bg: "#7a7a8818"},
    # unknown — we couldn't determine health (cold cache / sync pipeline
    # down). Treated as a RED alert like offline, not neutral: a missing
    # status IS a problem worth surfacing. Label stays "Unknown" to keep
    # it honest (not confirmed-down).
    unknown: {label: "Unknown", color: "var(--voodu-red)", bg: "var(--voodu-red-dim)"}
  }.freeze

  def initialize(status:, label: nil)
    @status = status.to_sym
    @label = label
  end

  def view_template
    s = STATES.fetch(@status, STATES[:stopped])
    label = @label || s[:label]

    span(
      class: "inline-flex items-center gap-1.5 px-2 py-[3px] text-[11px] font-medium leading-relaxed",
      style: "background: #{s[:bg]}; color: #{s[:color]}; border: 1px solid #{s[:color]}22;"
    ) do
      if @status == :restarting
        render Components::UI::Spinner.new(color: s[:color], size: 10)
      else
        span(
          class: "inline-block rounded-full",
          style: "width: 6px; height: 6px; background: #{s[:color]};"
        )
      end
      plain label
    end
  end
end
