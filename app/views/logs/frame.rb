# frozen_string_literal: true

# Views::Logs::Frame — the Turbo Frame partial that the polling
# controller reloads every 5s. Renders only the log text + the frame
# tag so the surrounding chrome (sidebar/topbar/header) doesn't
# re-render on each tick.
class Views::Logs::Frame < Views::Base
  def initialize(pod_name:, logs:, error: nil)
    @pod_name = pod_name
    @logs = logs
    @error = error
  end

  def view_template
    turbo_frame_tag("logs", class: "flex-1 overflow-hidden") do
      if @error
        div(class: "p-4 text-voodu-red text-sm") { @error.message }
      elsif @logs.blank?
        div(class: "p-4 text-voodu-muted text-sm") { "no log lines yet." }
      else
        # Reverse order: newest line at top, oldest at the bottom.
        # Operators glancing at logs to debug "what just happened" see
        # the freshest line first without scrolling. Each refresh tick
        # naturally lands new content where the eye already is (top).
        pre(
          class: "h-full overflow-auto px-4 py-3 font-voodu-mono text-[11.5px] leading-relaxed text-voodu-text-2 bg-voodu-bg"
        ) { @logs.lines.reverse.join }
      end
    end
  end
end
